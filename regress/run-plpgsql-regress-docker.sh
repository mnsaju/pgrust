#!/usr/bin/env bash
# Runs upstream PostgreSQL's *supplementary* PL/pgSQL regression suites
# (vendor/postgresql/src/pl/plpgsql/src/{sql,expected}, the REGRESS list from
# that directory's Makefile) against a real pgrust server in Docker.
#
# These 13 suites are not part of src/test/regress: the core schedule runs a
# single large `plpgsql` test, while procedure/transaction control, record
# types, cursors, domains and COPY-inside-plpgsql live only here. pgrust ports
# PL/pgSQL (crates/pl/plpgsql), so they are runnable as-is.
#
# Topology -- deliberately different from the two older runners. Those
# `docker exec` pg_regress into the server's own container; this one keeps the
# driver and the server apart:
#
#     [ driver container ]  --TCP-->  [ pgrust server container ]
#      pg_regress, psql                 pgrust-postgres
#            \___________ shared docker network ___________/
#
# so a driver that misbehaves cannot be mistaken for a server fault, and the
# connection under test is the ordinary client/server one rather than a
# loopback socket inside one container. Both containers come from the SAME
# image, which keeps libpq/pg_regress and the server at matching versions.
#
# Two mounts must be identical in both containers, because plpgsql_copy runs
# *server-side* COPY against paths pg_regress derives from its own directory
# flags (pg_regress.c: PG_ABS_SRCDIR=--inputdir, PG_ABS_BUILDDIR=--outputdir):
#   /plpgsql-src  (ro)  the suite; the server reads data/copy1.data from it
#   /plpgsql-out  (rw)  pg_regress's outputdir; the server writes results/ into it
# Mount them at different paths and plpgsql_copy fails in a way that looks like
# a pgrust COPY defect.
#
# Usage: regress/run-plpgsql-regress-docker.sh [--allow-file PATH] [test ...]
#   --allow-file turns the run into a CI gate with the same ratchet semantics
#   as the core and contrib suites: a listed test may fail, an unlisted failure
#   breaks the build, and a listed test that starts passing is stale and also
#   breaks the build -- so the ledger can only shrink.
#   With no test arguments, runs the Makefile's full REGRESS list.
#
# Requires: docker. Set PGRUST_IMAGE to reuse an already-built image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:regress}"
SRC="$REPO_ROOT/vendor/postgresql/src/pl/plpgsql/src"
WORK="$REPO_ROOT/regress-work/plpgsql"
OUTDIR="$WORK/output"
# Per-invocation names: a fixed name means a second run (reproducing one test
# while a sweep is in flight) `docker rm -f`s the first run's containers out
# from under it, and the sweep dies with status 137 -- which reads exactly like
# a pgrust crash. Same lesson as the contrib runner.
SERVER="pgrust-plpgsql-server-$$"
DRIVER="pgrust-plpgsql-driver-$$"
NETWORK="pgrust-plpgsql-net-$$"
REGRESS_BIN=/usr/lib/postgresql/18/lib/pgxs/src/test/regress/pg_regress
DB=plpgsql_regress

if [ ! -d "$SRC/sql" ]; then
    echo "FAIL: $SRC missing -- run: git submodule update --init vendor/postgresql" >&2
    exit 2
fi

cleanup() {
    docker rm -f "$SERVER" "$DRIVER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ALLOW_FILE=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-file) ALLOW_FILE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ $# -gt 0 ]; then
    TESTS="$*"
else
    # REGRESS is continued across lines with backslashes, and this list is
    # three lines long. A plain `sed -n 's/^REGRESS *= *//p'` returns only the
    # first line -- 4 of the 13 tests -- and the run still looks healthy, so
    # join the continuations explicitly.
    TESTS="$(awk '
        /^REGRESS[[:space:]]*=/ { sub(/^REGRESS[[:space:]]*=[[:space:]]*/, ""); inlist = 1 }
        inlist {
            cont = /\\$/
            sub(/[[:space:]]*\\$/, "")
            printf "%s ", $0
            if (!cont) exit
        }
    ' "$SRC/Makefile")"
fi
[ -n "${TESTS// }" ] || { echo "FAIL: no tests to run" >&2; exit 2; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building the pgrust image (none cached for $IMAGE)"
    docker build -t "$IMAGE" "$REPO_ROOT"
else
    echo "==> Reusing image $IMAGE"
fi

# Two writers with different uids share this tree: the driver container (root)
# and the server container (postgres, uid 999, via plpgsql_copy's server-side
# COPY TO). Unlinking a file needs write permission on its *directory*, not the
# file, so every directory pg_regress will write into is pre-created 0777 --
# otherwise the next run cannot clean up after this one. The initial clean runs
# in a container because an earlier run may have left root-owned directories
# that predate this rule.
if [ -d "$WORK" ]; then
    docker run --rm -v "$REPO_ROOT/regress-work":/rw "$IMAGE" rm -rf /rw/plpgsql
fi
mkdir -p "$OUTDIR/results" "$OUTDIR/log"
chmod 777 "$OUTDIR" "$OUTDIR/results" "$OUTDIR/log"

echo "==> Creating network $NETWORK"
docker network create "$NETWORK" >/dev/null

echo "==> Starting the pgrust server container (C-locale initdb, matching expected/*.out)"
docker run -d --name "$SERVER" --network "$NETWORK" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--locale=C --encoding=UTF8" \
    -v "$SRC":/plpgsql-src:ro \
    -v "$OUTDIR":/plpgsql-out \
    "$IMAGE" >/dev/null

# Readiness is checked FROM a driver container, not with `docker exec` into the
# server: the thing that must work is cross-container TCP, so test that.
driver() { docker run --rm --network "$NETWORK" -e PGHOST="$SERVER" -e PGUSER=postgres "$@"; }

echo "==> Waiting for the server to accept connections from a driver container"
ready=0
for _ in $(seq 1 90); do
    if driver "$IMAGE" psql -c 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: server never became reachable from the driver container"
    docker logs "$SERVER" || true
    exit 2
fi

# Replicates pg_regress's own create_database() SQL: --use-existing skips
# database creation (pg_regress.c: `if (!use_existing) { create_database(...) }`),
# so the locale/encoding setup the expected/*.out files assume is ours to do.
driver "$IMAGE" psql -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
driver "$IMAGE" psql -v ON_ERROR_STOP=1 -q \
    -c "CREATE DATABASE $DB TEMPLATE=template0 ENCODING='UTF8' LOCALE='C';" >/dev/null
driver "$IMAGE" psql -v ON_ERROR_STOP=1 -q -c "
    ALTER DATABASE $DB SET lc_messages TO 'C';
    ALTER DATABASE $DB SET lc_monetary TO 'C';
    ALTER DATABASE $DB SET lc_numeric TO 'C';
    ALTER DATABASE $DB SET lc_time TO 'C';
    ALTER DATABASE $DB SET bytea_output TO 'hex';
    ALTER DATABASE $DB SET timezone_abbreviations TO 'Default';
" >/dev/null

echo "==> Running pg_regress from a separate driver container against $SERVER"
status=0
# shellcheck disable=SC2086 -- $TESTS is an intentional word list
docker run --rm --name "$DRIVER" --network "$NETWORK" \
    -v "$SRC":/plpgsql-src:ro \
    -v "$OUTDIR":/plpgsql-out \
    -w /plpgsql-src \
    "$IMAGE" "$REGRESS_BIN" \
        --use-existing --host="$SERVER" --port=5432 --user=postgres \
        --dbname="$DB" \
        --inputdir=/plpgsql-src --outputdir=/plpgsql-out \
        $TESTS >"$WORK/plpgsql.log" 2>&1 || status=$?

sed -e 's/^/    /' "$WORK/plpgsql.log" | grep -E 'ok |^\s+# ' || true

# PostgreSQL 18's pg_regress emits TAP: "ok 1 - name" / "not ok 2 - name".
mapfile -t FAILED < <(grep -E '^not ok [0-9]+' "$WORK/plpgsql.log" | sed -E 's/^not ok [0-9]+[[:space:]]+-[[:space:]]+([^[:space:]]+).*/\1/' | sort -u)
mapfile -t PASSED < <(grep -E '^ok [0-9]+' "$WORK/plpgsql.log" | sed -E 's/^ok [0-9]+[[:space:]]+-[[:space:]]+([^[:space:]]+).*/\1/' | sort -u)

echo
echo "==> plpgsql summary: ${#PASSED[@]} passed, ${#FAILED[@]} failed (pg_regress status=$status)"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "    failed:"; printf '      - %s\n' "${FAILED[@]}"
fi
echo "==> logs + diffs under $WORK"

# pg_regress exits 1 for "some tests failed" and 2 for "could not run at all".
# Only the latter is a harness error; the former is an outcome the ledger
# judges. Same contract as the core and contrib runners.
if [ "$status" -ge 2 ]; then
    echo "FAIL: pg_regress could not run (status=$status)" >&2
    exit 2
fi

if [ -z "$ALLOW_FILE" ]; then
    exit 0
fi
if [ ! -f "$ALLOW_FILE" ]; then
    echo "FAIL: --allow-file $ALLOW_FILE not found" >&2
    exit 2
fi

mapfile -t ALLOWED < <(sed 's/#.*//' "$ALLOW_FILE" | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u)
new_failures="$(comm -13 <(printf '%s\n' "${ALLOWED[@]+"${ALLOWED[@]}"}") <(printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | grep -v '^$'))"
stale="$(comm -23 <(printf '%s\n' "${ALLOWED[@]+"${ALLOWED[@]}"}") <(printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | grep -v '^$'))"

echo
echo "==> ratchet ledger: $ALLOW_FILE (${#ALLOWED[@]} entries)"
rc=0
if [ -n "$new_failures" ]; then
    echo "    NEW failures (not in ledger):"; echo "$new_failures" | sed 's/^/      - /'
    rc=1
fi
if [ -n "$stale" ]; then
    echo "    STALE entries (now passing -- remove them):"; echo "$stale" | sed 's/^/      - /'
    rc=1
fi
[ "$rc" -eq 0 ] && echo "    no new failures, no stale entries"
exit "$rc"
