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
# The stack limit MUST come from the container, not from the shim. pgrust
# records its real path in postmaster.opts, so `pg_ctl restart` re-execs the
# binary directly and the shim -- along with its `ulimit -s` -- is not in the
# loop at all. The server then refuses to boot:
#     FATAL: invalid value for parameter "max_stack_depth": 60000
#     DETAIL: "max_stack_depth" must not exceed 7680kB.
# 001_stream_rep calls restart, BAIL_OUTs on the failure, and one bail aborts
# the whole prove run -- 42 tests reduced to 1. Setting the limit on the
# container makes every start path work, however the server is launched.
docker run -d --name "$CONTAINER" \
    -v "$SRC:/pgsrc:ro" -v "$WORK:/tapwork" \
    --ulimit stack=67092480:67092480 -e RUST_MIN_STACK=33554432 \
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
# Five of the 47 cannot run here for architectural reasons, not because they
# are hard: they take a pid out of SQL and signal it from outside the server,
# and pgrust's pids are synthetic. They are excluded rather than ledgered --
# see regress/recovery-not-applicable.txt for why, and for what each one costs
# us -- but they are ALWAYS printed, because an absent test is not a passing
# one and a suite that quietly runs 42 while reporting on 47 is exactly the
# defect this tier was built to rule out.
NA_FILE="$REPO_ROOT/regress/recovery-not-applicable.txt"
declare -a NA=()
if [ -f "$NA_FILE" ]; then
    while IFS=$'\t' read -r t reason; do
        case "$t" in ''|\#*) continue ;; esac
        NA+=("$t")
        printf '  NOT APPLICABLE  %-30s %s\n' "$t" "$(echo "$reason" | cut -c1-84)..."
    done < "$NA_FILE"
fi
echo "==> ${#NA[@]} of 47 excluded as architecturally inapplicable (see $(basename "$NA_FILE"))"
echo

na_excluded() {
    for n in ${NA[@]+"${NA[@]}"}; do [ "t/$n" = "$1" ] && return 0; done
    return 1
}

if [ $# -eq 0 ] || [ "$1" = "ALL" ]; then
    TESTS=""
    for f in "$SRC/src/test/recovery/t"/*.pl; do
        rel="t/$(basename "$f")"
        na_excluded "$rel" || TESTS="$TESTS $rel"
    done
    TESTS="${TESTS# }"
else
    TESTS="$*"
fi

echo "==> Running recovery TAP: $(printf %s "$TESTS" | wc -w) tests, one prove per file"
echo

# ONE PROVE INVOCATION PER FILE, deliberately. PostgreSQL::Test calls BAIL_OUT
# when a cluster will not start or restart, and a bail aborts every remaining
# file in the SAME prove run: the first attempt at this suite reported on 1
# file of 42 for that reason, the second on 23. A tier whose job is to seed a
# ledger cannot let one sick test hide the other forty-one -- the same rule
# regress/run-compat-lanes.sh follows for the Gate B lanes.
declare -a T_PASS=() T_FAIL=() T_BAIL=() T_TIMEOUT=() T_SKIP=()
: > "$WORK/recovery-full.log"
for t in $TESTS; do
    out="$WORK/tap-one.out"
    # TESTDATADIR/TESTLOGDIR, not TESTDIR: PostgreSQL::Test::Utils reads
    #     $tmp_check = $ENV{TESTDATADIR} ? "$ENV{TESTDATADIR}" : "tmp_check";
    # and ignores TESTDIR entirely. With only TESTDIR set, tmp_check fell back
    # to the RELATIVE "tmp_check", and Cluster.pm then built
    #     archive_command = 'cp "%p" "tmp_check/t_..._data/archives/%f"'
    # The test process resolves that (its cwd is the suite dir); the archiver
    # process does not, because the postmaster chdirs to PGDATA at startup. So
    # every cp wrote into a path that did not exist, the archive stayed empty,
    # and all eight archive/replay tests timed out waiting for WAL that was
    # never archived -- looking exactly like a pgrust durability defect.
    set +e
    docker exec \
        -e "PATH=$SHIM_PATH" \
        -e "PERL5LIB=/pgsrc/src/test/perl" \
        -e "PGRUST_TAP_WITNESS=$WITNESS" \
        -e "TESTDIR=/tapwork/suite" \
        -e "TESTDATADIR=/tapwork/suite/tmp_check" \
        -e "TESTLOGDIR=/tapwork/suite/log" \
        -e "PG_REGRESS=/usr/lib/postgresql/18/lib/pgxs/src/test/regress/pg_regress" \
        -e "TMPDIR=/tapwork/tmp" -e TZ=UTC -e PG_TEST_NOCLEAN=1 \
        -e "enable_injection_points=no" \
        -w /tapwork/suite \
        "$CONTAINER" sh -c "timeout -k 30 ${PGRUST_TAP_PER_TEST:-600} prove --verbose $t" \
        > "$out" 2>&1
    rc=$?
    set -e
    name="$(basename "$t")"
    # A skip is NOT a pass. Five of these tests skip themselves when the build
    # lacks injection points, and folding those into the pass count would
    # inflate the evidence with tests that never ran a single assertion --
    # `enable_injection_points=no` above is what lets them skip cleanly instead
    # of dying on an uninitialized-value warning, which is how they first
    # showed up as failures.
    case "$rc" in
        0)  # prove renders a skip_all as "skipped: <reason>" with
            # "Result: NOTESTS" -- NOT as "1..0 # SKIP", which is what a first
            # attempt at this guard looked for and why four skipped tests were
            # briefly reported as passes.
            if grep -qE '^Result: NOTESTS|skipped: ' "$out"; then
                T_SKIP+=("$name"); printf '  SKIP     %-32s %s\n' "$name" \
                    "$(grep -m1 -oE 'skipped: .*' "$out" | cut -c1-52)"
            else
                T_PASS+=("$name"); printf '  PASS     %s\n' "$name"
            fi ;;
        124) T_TIMEOUT+=("$name"); printf '  TIMEOUT  %-32s killed after %ss\n' "$name" "${PGRUST_TAP_PER_TEST:-600}" ;;
        255) T_BAIL+=("$name");    printf '  BAIL     %-32s %s\n' "$name" \
                 "$(grep -m1 -oE 'Further testing stopped:.*' "$out" | cut -c1-56)" ;;
        *)   T_FAIL+=("$name");    printf '  FAIL     %-32s exit %-4s %s\n' "$name" "$rc" \
                 "$(grep -m1 -oE 'poll_query_until timed out.*' "$out" | cut -c1-44)" ;;
    esac
    { echo "########## $name (exit $rc)"; cat "$out"; } >> "$WORK/recovery-full.log"
    rm -f "$out"
done

echo
echo "==> recovery TAP: ${#T_PASS[@]} passed, ${#T_FAIL[@]} failed, ${#T_SKIP[@]} skipped, ${#T_BAIL[@]} bailed, ${#T_TIMEOUT[@]} timed out"
echo "    plus ${#NA[@]} excluded as architecturally inapplicable"
for pair in "FAIL:${T_FAIL[*]-}" "SKIP:${T_SKIP[*]-}" "BAIL:${T_BAIL[*]-}" "TIMEOUT:${T_TIMEOUT[*]-}"; do
    [ -n "${pair#*:}" ] && printf '    %-8s %s\n' "${pair%%:*}" "${pair#*:}"
done
STATUS=$([ $(( ${#T_FAIL[@]} + ${#T_BAIL[@]} + ${#T_TIMEOUT[@]} )) -eq 0 ] && echo 0 || echo 1)
echo "==> logs + node data kept under $WORK (PG_TEST_NOCLEAN=1)"
echo "==> backend launches recorded: $(docker exec "$CONTAINER" sh -c "wc -l < $WITNESS" 2>/dev/null || echo 0)"
exit "$STATUS"
