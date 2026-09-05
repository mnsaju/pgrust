#!/usr/bin/env bash
# Runs PostgreSQL's real regression + isolation test suites (vendored at
# vendor/postgresql, merged with pgrust's overlay by
# scripts/lane-epq-inc1-e2e.sh) against a real pgrust server in Docker.
#
# This is PGRA-017's (review/opus/findings.md) missing runner: the
# repo's "passes the PostgreSQL regression suite" claim was previously
# unverifiable because this script, and the vendored suite it drives,
# didn't exist. Uses `pg_regress --use-existing`/`pg_isolation_regress
# --use-existing` ("existing installation" mode, the same mode
# `make installcheck` uses) against the pgrust container's own postmaster,
# rather than pg_regress's own temp-instance mode -- no separate driver
# image needed: PGDG's postgresql-client-18 (already in the repo's
# Dockerfile) ships pg_regress/pg_isolation_regress/isolationtester at
# /usr/lib/postgresql/18/lib/pgxs/src/test/{regress,isolation}/, and the
# final image stage already copies that whole tree forward.
#
# Usage: regress/run-regress-docker.sh [--schedule-file PATH] [--isolation-schedule-file PATH]
#   --schedule-file / --isolation-schedule-file override which schedule to
#   run (default: the full merged parallel_schedule / isolation_schedule).
#   Use this to validate the pipeline against a handful of test groups
#   before committing to the full run -- e.g.:
#     printf 'test: test_setup\ntest: boolean\ntest: select\n' > /tmp/mini
#     regress/run-regress-docker.sh --schedule-file /tmp/mini
#
# Requires: docker. Set PGRUST_IMAGE to reuse an already-built image;
# otherwise this builds one from the repository root.
#
# Runtime: the full suite is ~46,000 individual statements across ~230
# files plus ~130 isolation specs -- expect this to take a long time.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:regress}"
CONTAINER="pgrust-regress-suite"
WORK="$REPO_ROOT/regress-work"

SCHEDULE_FILE=""
ISOLATION_SCHEDULE_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --schedule-file) SCHEDULE_FILE="$2"; shift 2 ;;
        --isolation-schedule-file) ISOLATION_SCHEDULE_FILE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building the pgrust Docker image (no cached image found for $IMAGE)"
    docker build -t "$IMAGE" "$REPO_ROOT"
else
    echo "==> Reusing existing image $IMAGE (set PGRUST_IMAGE=<other> or remove it to rebuild)"
fi

echo "==> Building the merged regress/isolation inputdirs"
bash "$REPO_ROOT/scripts/lane-epq-inc1-e2e.sh" "$WORK"

[ -n "$SCHEDULE_FILE" ] && cp "$SCHEDULE_FILE" "$WORK/regress/schedule.run" || cp "$WORK/regress/parallel_schedule" "$WORK/regress/schedule.run"
[ -n "$ISOLATION_SCHEDULE_FILE" ] && cp "$ISOLATION_SCHEDULE_FILE" "$WORK/isolation/schedule.run" || cp "$WORK/isolation/isolation_schedule" "$WORK/isolation/schedule.run"

cleanup
echo "==> Starting a container with C-locale initdb (matches expected/*.out's baked-in assumptions)"
docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=regress-secret \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" \
    -v "$WORK/regress:/regress-input:ro" \
    -v "$WORK/isolation:/isolation-input:ro" \
    "$IMAGE" postgres -c max_prepared_transactions=10 >/dev/null

# Gate on a TCP connection, not on the unix socket. The postgres entrypoint
# runs initdb against a temporary server started with listen_addresses='' and
# then shuts it down before starting the real one; `pg_isready` over the socket
# answers YES to that temporary server, so the script raced ahead and the next
# psql got "FATAL: the database system is shutting down". A TCP probe cannot
# see the init server at all, which is why the contrib and plpgsql runners --
# both of which connect over the network -- never hit this.
ready=0
for _ in $(seq 1 90); do
    if docker exec "$CONTAINER" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: server never became ready"
    docker logs "$CONTAINER" || true
    exit 1
fi

docker exec -u postgres "$CONTAINER" mkdir -p /tmp/regress-output /tmp/isolation-output

# `--use-existing` deliberately skips database creation (pg_regress.c:
# `if (!use_existing) { create_database(...) }`) -- "existing installation"
# mode means exactly that: you're responsible for creating the test
# database(s) yourself. This replicates create_database()'s own SQL
# (pg_regress.c create_database) exactly, so the databases end up with the
# same locale/encoding/session-GUC setup a real pg_regress-driven
# temp-instance run would have produced.
psqlpg() { docker exec -u postgres "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
for db in regression isolation_regression; do
    # DROP DATABASE / CREATE DATABASE each refuse to run inside a
    # transaction block -- and psql sends a multi-statement -c string as
    # one implicit transaction -- so each needs its own -c call.
    psqlpg "DROP DATABASE IF EXISTS \"$db\";"
    psqlpg "CREATE DATABASE \"$db\" TEMPLATE=template0 ENCODING='UTF8' LOCALE='C';"
    psqlpg "
        ALTER DATABASE \"$db\" SET lc_messages TO 'C';
        ALTER DATABASE \"$db\" SET lc_monetary TO 'C';
        ALTER DATABASE \"$db\" SET lc_numeric TO 'C';
        ALTER DATABASE \"$db\" SET lc_time TO 'C';
        ALTER DATABASE \"$db\" SET bytea_output TO 'hex';
        ALTER DATABASE \"$db\" SET timezone_abbreviations TO 'Default';
    "
done

echo "==> Running pg_regress"
# A hang must be a defined failure, not an open-ended wait. This suite runs in
# about a minute on a hosted runner and a few minutes locally; run
# 33967785391 sat in it for over half an hour with no output and would have
# burned GitHub's six-hour default job timeout before failing with nothing to
# show. `timeout` runs INSIDE the container so the driver dies with it, and
# exit 124 is reported distinctly below -- a hang and a test failure are
# different findings and must not arrive looking the same.
REGRESS_TIMEOUT="${PGRUST_REGRESS_TIMEOUT:-1200}"
REGRESS_BIN=/usr/lib/postgresql/18/lib/pgxs/src/test/regress/pg_regress
REGRESS_STATUS=0
docker exec -u postgres "$CONTAINER" timeout -k 30 "$REGRESS_TIMEOUT" "$REGRESS_BIN" \
    --use-existing --host=localhost --port=5432 --user=postgres \
    --dbname=regression \
    --inputdir=/regress-input --outputdir=/tmp/regress-output \
    --schedule=/regress-input/schedule.run \
    || REGRESS_STATUS=$?

echo "==> Running pg_isolation_regress"
ISOLATION_BIN=/usr/lib/postgresql/18/lib/pgxs/src/test/isolation/pg_isolation_regress
ISOLATION_STATUS=0
docker exec -u postgres "$CONTAINER" timeout -k 30 "$REGRESS_TIMEOUT" "$ISOLATION_BIN" \
    --use-existing --host=localhost --port=5432 --user=postgres \
    --dbname=isolation_regression \
    --inputdir=/isolation-input --outputdir=/tmp/isolation-output \
    --schedule=/isolation-input/schedule.run \
    || ISOLATION_STATUS=$?

echo "==> Copying results out for the rowsort comparator / inspection"
rm -rf "$WORK/regress-output" "$WORK/isolation-output"
docker cp "$CONTAINER:/tmp/regress-output" "$WORK/regress-output" >/dev/null
docker cp "$CONTAINER:/tmp/isolation-output" "$WORK/isolation-output" >/dev/null

echo "==> pg_regress exit status: $REGRESS_STATUS (0=all passed, 1=some failed, 2=could not run)"
echo "==> pg_isolation_regress exit status: $ISOLATION_STATUS"
for pair in "pg_regress:$REGRESS_STATUS" "pg_isolation_regress:$ISOLATION_STATUS"; do
    if [ "${pair#*:}" -eq 124 ]; then
        echo "FAIL: ${pair%%:*} HUNG and was killed after ${REGRESS_TIMEOUT}s."
        echo "      This is not a test failure. The suite normally finishes in"
        echo "      about a minute on a hosted runner. Treat it as a"
        echo "      concurrency finding and keep the artifacts: something"
        echo "      blocked and never came back."
    fi
done
if [ -f "$WORK/regress-output/regression.diffs" ]; then
    echo "==> raw regress diffs: $WORK/regress-output/regression.diffs"
fi
if [ -f "$WORK/isolation-output/regression.diffs" ]; then
    echo "==> raw isolation diffs: $WORK/isolation-output/regression.diffs"
fi

# Pass --schedule-file: it is the only input that tells the comparator what this
# run was asked to execute, so a test that died before writing any output is an
# error rather than a silent absence.
cat <<HINT
==> Next: reclassify the raw diffs against the overlay's annotations and ratchet:
    python3 scripts/rowsort_compare.py \\
        --sql-dir regress/overlay/sql \\
        --actual-dir $WORK/regress-output/results \\
        --expected-dir $WORK/regress/expected \\
        --schedule-file $WORK/regress/schedule.run \\
        --allow-file regress/known-failures.allow
HINT

# Exit status 2 from either driver means "could not run at all" (a harness
# problem, e.g. the server never came up correctly) -- that's a real script
# failure. Status 1 ("some tests failed") is a legitimate, expected outcome
# to report on, not a script error.
if [ "$REGRESS_STATUS" -eq 124 ] || [ "$ISOLATION_STATUS" -eq 124 ]; then
    echo "FAIL: a driver hung (see above); failing rather than letting the job"
    echo "      run to its own timeout with nothing collected."
    exit 1
fi
if [ "$REGRESS_STATUS" -eq 2 ] || [ "$ISOLATION_STATUS" -eq 2 ]; then
    echo "FAIL: a driver could not run the suite at all (status 2) -- see docker logs $CONTAINER"
    exit 1
fi
exit 0
