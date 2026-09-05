#!/usr/bin/env bash
# Runs upstream's src/test/recovery TAP suite against a real pgrust server.
#
# Gate A1 of PLAN-production-readiness.md. These 47 tests are the only
# automated evidence available for crash recovery, PITR, promotion, timeline
# switches and standby behaviour -- the areas the assessment rates RED from
# static reading alone.
#
# THE TRAP THIS SCRIPT EXISTS TO CLOSE. PostgreSQL::Test::Cluster starts
# servers with a bare `pg_ctl`, and pg_ctl finds `postgres` next to itself, not
# on $PATH. In the pgrust image that name belongs to the C backend. Pointed at
# the suite naively, TAP therefore tests C PostgreSQL and reports a GREEN run.
# regress/tap/postgres-shim documents the two-entry bindir that redirects it.
#
# Because the failure mode is a pass, this runner refuses to report anything
# until it has demonstrated, in both directions, that it can tell the two
# servers apart:
#
#   preflight  a cluster started through the shim answers version() as pgrust
#   control    the same start WITHOUT the shim answers as C, and is REJECTED
#
# If either check misbehaves the suite does not run. A green recovery result is
# worth nothing without them.
#
# Usage:
#   regress/run-recovery-tap-docker.sh                 # preflight + control + 001
#   regress/run-recovery-tap-docker.sh t/002_archiving.pl t/003_recovery_targets.pl
#   regress/run-recovery-tap-docker.sh --all           # the whole suite
#   regress/run-recovery-tap-docker.sh --preflight-only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
TAP_IMAGE="${PGRUST_TAP_IMAGE:-pgrust:tap}"
CONTAINER="pgrust-recovery-tap-$$"
SRC="$REPO_ROOT/vendor/postgresql"
WORK="$REPO_ROOT/regress-work/recovery"

PREFLIGHT_ONLY=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        --all) ARGS+=(ALL) ;;
        *) ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[ -d "$SRC/src/test/recovery/t" ] || {
    echo "FAIL: vendor/postgresql not checked out (git submodule update --init --depth 1 vendor/postgresql)" >&2
    exit 2
}

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker image inspect "$TAP_IMAGE" >/dev/null 2>&1; then
    echo "==> Building the TAP driver image ($TAP_IMAGE from $BASE_IMAGE)"
    docker build --build-arg "BASE=$BASE_IMAGE" -f "$REPO_ROOT/regress/tap/Dockerfile" \
        -t "$TAP_IMAGE" "$REPO_ROOT/regress/tap"
else
    echo "==> Reusing $TAP_IMAGE"
fi

# The container runs as postgres (uid 999) while this tree is owned by the host
# user, and unlinking needs write permission on the DIRECTORY, not the file --
# the same two-uid problem run-plpgsql-regress-docker.sh documents. A host-side
# `rm -rf` therefore fails on everything the last run created, so the clean
# happens in a throwaway root container.
mkdir -p "$WORK"
docker run --rm -v "$WORK:/w" --entrypoint sh "$TAP_IMAGE" \
    -c 'rm -rf /w/* /w/.[!.]* 2>/dev/null; exit 0'
chmod 0777 "$WORK"

# One long-lived container; TAP starts and stops its own clusters inside it.
# --user postgres because pgrust refuses to run as root, like C.
docker run -d --name "$CONTAINER" \
    -v "$SRC:/pgsrc:ro" -v "$WORK:/tapwork" \
    --user postgres --entrypoint sleep "$TAP_IMAGE" infinity >/dev/null
# Upstream's suite writes into its own directory, so give it a writable copy.
docker exec "$CONTAINER" cp -a /pgsrc/src/test/recovery /tapwork/suite
docker exec "$CONTAINER" sh -c 'mkdir -p /tapwork/tmp && chmod 0777 /tapwork/tmp'

WITNESS=/tapwork/witness.log

# ---------------------------------------------------------------------------
# Preflight and control. Same code path both times; the ONLY difference is
# whether the shim bindir is on PATH.
# ---------------------------------------------------------------------------
probe() {
    # $1: PATH to use.  Prints the server's version() or "START-FAILED".
    docker exec -e "PATH=$1" -e "PGRUST_TAP_WITNESS=$WITNESS" \
        -e TZ=UTC "$CONTAINER" sh -c '
            set -e
            d=$(mktemp -d /tapwork/tmp/probe.XXXXXX)
            initdb -D "$d/data" --no-locale --encoding=UTF8 -U postgres >/dev/null 2>&1
            echo "unix_socket_directories = '"'"'$d'"'"'" >> "$d/data/postgresql.conf"
            echo "listen_addresses = '"'"''"'"'" >> "$d/data/postgresql.conf"
            if ! pg_ctl -D "$d/data" -l "$d/log" -w -t 30 start >/dev/null 2>&1; then
                echo START-FAILED; sed -n "1,12p" "$d/log" >&2 || true; exit 0
            fi
            psql -h "$d" -U postgres -d postgres -Atc "SELECT version()" 2>/dev/null || echo QUERY-FAILED
            pg_ctl -D "$d/data" -m immediate -w stop >/dev/null 2>&1 || true
        ' 2>&1 | tail -1
}

SHIM_PATH=/opt/pgrust-tapbin:/usr/lib/postgresql/18/bin:/usr/local/bin:/usr/bin:/bin
BARE_PATH=/usr/lib/postgresql/18/bin:/usr/local/bin:/usr/bin:/bin

echo "==> Preflight: start a cluster THROUGH the shim and ask who answered"
docker exec "$CONTAINER" sh -c ": > $WITNESS"
pre="$(probe "$SHIM_PATH")"
echo "    version(): $pre"
case "$pre" in
    pgrust*) echo "    OK — the server under test is pgrust" ;;
    *) echo "FAIL: the shim did not produce a pgrust server (got: $pre)." >&2
       echo "      Refusing to run the suite; a result now would describe the wrong server." >&2
       exit 1 ;;
esac
if ! docker exec "$CONTAINER" test -s "$WITNESS"; then
    echo "FAIL: the shim never recorded a backend launch. pg_ctl resolved some other postgres." >&2
    exit 1
fi

echo "==> Control: start the SAME way WITHOUT the shim; this MUST NOT be pgrust"
ctl="$(probe "$BARE_PATH")"
echo "    version(): $ctl"
case "$ctl" in
    pgrust*) echo "FAIL: the control run also produced pgrust, so this harness cannot" >&2
             echo "      distinguish the two servers and its verdicts are meaningless." >&2
             exit 1 ;;
    PostgreSQL*) echo "    OK — control is C PostgreSQL, so the two are distinguishable" ;;
    *) echo "FAIL: control run did not start a server at all (got: $ctl); the negative" >&2
       echo "      control proves nothing in that state." >&2
       exit 1 ;;
esac

[ "$PREFLIGHT_ONLY" -eq 1 ] && { echo "==> --preflight-only: both controls passed."; exit 0; }

# ---------------------------------------------------------------------------
# The suite
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    TESTS="t/001_stream_rep.pl"
elif [ "$1" = "ALL" ]; then
    TESTS=""
else
    TESTS="$*"
fi

echo "==> Running recovery TAP: ${TESTS:-<all>}"
set +e
docker exec \
    -e "PATH=$SHIM_PATH" \
    -e "PERL5LIB=/pgsrc/src/test/perl" \
    -e "PGRUST_TAP_WITNESS=$WITNESS" \
    -e "TESTDIR=/tapwork/suite" \
    -e "PG_REGRESS=/usr/lib/postgresql/18/lib/pgxs/src/test/regress/pg_regress" \
    -e "TMPDIR=/tapwork/tmp" -e TZ=UTC -e PG_TEST_NOCLEAN=1 \
    -w /tapwork/suite \
    "$CONTAINER" sh -c "timeout -k 30 ${PGRUST_TAP_TIMEOUT:-1800} prove --verbose ${TESTS:-t/*.pl}"
STATUS=$?
set -e

echo
if [ "$STATUS" -eq 124 ]; then
    echo "==> prove TIMED OUT after ${PGRUST_TAP_TIMEOUT:-1800}s (raise PGRUST_TAP_TIMEOUT)."
    echo "    A timeout is a FAILURE, not an inconclusive run: upstream's own"
    echo "    pump_until waits are 180s each, so a test that outruns this budget"
    echo "    is one where pgrust never produced the signal the test waits for."
fi
echo "==> prove exit status: $STATUS"
echo "==> logs + node data kept under $WORK (PG_TEST_NOCLEAN=1)"
echo "==> backend launches recorded: $(docker exec "$CONTAINER" wc -l < "$WITNESS" 2>/dev/null || echo 0)"
exit "$STATUS"
