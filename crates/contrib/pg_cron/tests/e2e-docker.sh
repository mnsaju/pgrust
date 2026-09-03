#!/usr/bin/env bash
# End-to-end verification of pg_cron against a real pgRust server, using the
# repository's own Docker image rather than requiring a live Postgres +
# pg_regress on the host.
#
# What this proves that the pure-Rust unit tests in src/tests.rs cannot:
#   - the SQL API (cron.schedule/schedule_in_database/alter_job/unschedule)
#     actually works against a real catalog, including the upsert-on-conflict
#     and not-found-raises-exception paths
#   - schedule_in_database's superuser-only cross-user/cross-database check
#     actually blocks a non-superuser role
#   - the launcher bgworker actually fires jobs on a real minute boundary via
#     SPI, and records both success and failure to cron.job_run_details
#     without wedging on the failure
#   - cron.max_running_jobs actually bounds concurrent job workers
#   - the launcher survives a container restart and resumes scheduling
#
# Usage: crates/contrib/pg_cron/tests/e2e-docker.sh
# Requires: docker. Set PGRUST_IMAGE to reuse an already-built image (e.g.
# pgrust:pg_cron-e2e-v2); otherwise this builds one from the repository root
# (a full release build of the `postgres` binary — several minutes).
#
# Runtime: several minutes, most of it spent waiting for real minute
# boundaries (the SQL API surface itself is fast; the execution, cancel,
# concurrency, and restart/recovery sections each wait for cron to actually
# fire on schedule).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:pg_cron-e2e}"
CONTAINER="pgrust-pg_cron-e2e"

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

cleanup

wait_ready() {
    local container="$1" ready=0
    for _ in $(seq 1 30); do
        if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" -ne 1 ]; then
        echo "FAIL: $container never became ready"
        docker logs "$container" || true
        exit 1
    fi
}

# Sleeps until $1 seconds past the next UTC minute boundary, so a `* * * * *`
# job scheduled just before calling this is guaranteed to have had a chance
# to fire by the time it returns.
wait_past_minute_boundary() {
    local extra="${1:-8}" now wait_s
    now=$(date -u +%S)
    wait_s=$(( (60 - 10#$now) % 60 + extra ))
    sleep "$wait_s"
}

psqlc() { docker exec -u postgres "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 "$@"; }
psqlc_as() { local role="$1"; shift; docker exec -u postgres "$CONTAINER" psql -U "$role" -d postgres "$@"; }

echo "==> Starting a container with shared_preload_libraries=pg_cron"
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=e2e-secret -e POSTGRES_HOST_AUTH_METHOD=md5 "$IMAGE" \
    postgres -c shared_preload_libraries=pg_cron -c cron.database_name=postgres >/dev/null
wait_ready "$CONTAINER"

echo "==> CREATE EXTENSION pg_cron (must not crash-loop the launcher)"
psqlc -c "CREATE EXTENSION pg_cron;"
sleep 3
CRASHES=$(docker logs "$CONTAINER" 2>&1 | grep -c 'pg_cron scheduler.*exited with code' || true)
if [ "$CRASHES" -ne 0 ]; then
    echo "FAIL: pg_cron scheduler crashed $CRASHES time(s) after CREATE EXTENSION"
    docker logs "$CONTAINER" 2>&1 | tail -40
    exit 1
fi

echo "==> SQL API: cron.schedule/2, cron.schedule/3 upsert-on-conflict, alter_job, unschedule"
psqlc -c "SELECT cron.schedule('* * * * *', 'SELECT 1');"
ANON_ROWS=$(psqlc -tAc "SELECT count(*) FROM cron.job WHERE jobname IS NULL;")
if [ "$ANON_ROWS" != "1" ]; then
    echo "FAIL: cron.schedule/2 did not create exactly one unnamed job (found $ANON_ROWS)"
    exit 1
fi
psqlc -c "SELECT cron.schedule('named-job', '*/5 * * * *', 'SELECT 1');"
NAMED_JOBID=$(psqlc -tAc "SELECT jobid FROM cron.job WHERE jobname = 'named-job';")
psqlc -c "SELECT cron.schedule('named-job', '*/10 * * * *', 'SELECT 2');"
REJOBID=$(psqlc -tAc "SELECT jobid FROM cron.job WHERE jobname = 'named-job';")
if [ "$NAMED_JOBID" != "$REJOBID" ]; then
    echo "FAIL: re-scheduling an existing job name created a new row instead of upserting (was $NAMED_JOBID, now $REJOBID)"
    exit 1
fi
RESCHEDULE=$(psqlc -tAc "SELECT schedule FROM cron.job WHERE jobid = $REJOBID;")
if [ "$RESCHEDULE" != "*/10 * * * *" ]; then
    echo "FAIL: upsert did not update the schedule text (got '$RESCHEDULE')"
    exit 1
fi

psqlc -c "SELECT cron.alter_job($REJOBID, schedule => '*/15 * * * *');"
ALTERED=$(psqlc -tAc "SELECT schedule FROM cron.job WHERE jobid = $REJOBID;")
if [ "$ALTERED" != "*/15 * * * *" ]; then
    echo "FAIL: alter_job did not update schedule (got '$ALTERED')"
    exit 1
fi
ALTERED_CMD=$(psqlc -tAc "SELECT command FROM cron.job WHERE jobid = $REJOBID;")
if [ "$ALTERED_CMD" != "SELECT 2" ]; then
    echo "FAIL: alter_job's COALESCE touched a field it wasn't given (command changed to '$ALTERED_CMD')"
    exit 1
fi

psqlc -c "SELECT cron.unschedule($REJOBID);"
REMAINING=$(psqlc -tAc "SELECT count(*) FROM cron.job WHERE jobid = $REJOBID;")
if [ "$REMAINING" != "0" ]; then
    echo "FAIL: unschedule(bigint) did not remove the job"
    exit 1
fi
if docker exec -u postgres "$CONTAINER" psql -U postgres -tAc "SELECT cron.unschedule(999999);" >/dev/null 2>&1; then
    echo "FAIL: unschedule(bigint) of a nonexistent jobid should have raised an exception"
    exit 1
fi
if docker exec -u postgres "$CONTAINER" psql -U postgres -tAc "SELECT cron.unschedule('does not matter');" >/dev/null 2>&1; then
    echo "FAIL: unschedule(text) of a nonexistent name should have raised an exception"
    exit 1
fi

echo "==> Permissions: schedule_in_database's superuser-only cross-user/database check"
psqlc -c "CREATE ROLE plain_user LOGIN;" >/dev/null
if psqlc_as plain_user -v ON_ERROR_STOP=1 -c \
    "SELECT cron.schedule_in_database('sneaky', '* * * * *', 'SELECT 1', 'postgres', 'postgres');" >/dev/null 2>&1; then
    echo "FAIL: plain_user was able to schedule a job as a different username without being superuser"
    exit 1
fi
# Positive case: the same check must NOT block scheduling as yourself, in your own database.
psqlc_as plain_user -v ON_ERROR_STOP=1 -c \
    "SELECT cron.schedule_in_database('self-job', '* * * * *', 'SELECT 1', 'postgres', 'plain_user');" >/dev/null
psqlc -c "DELETE FROM cron.job WHERE jobname = 'self-job';" >/dev/null

echo "==> Execution: a succeeding and a failing job both record correctly without wedging the launcher"
psqlc -c "
    CREATE TABLE probe (id serial primary key, seen timestamptz);
    SELECT cron.schedule('probe-ok', '* * * * *', \$\$INSERT INTO probe (seen) VALUES (now())\$\$);
    SELECT cron.schedule('probe-fail', '* * * * *', 'SELECT this_is_not_a_function()');
"
wait_past_minute_boundary 10
PROBE_ROWS=$(psqlc -tAc "SELECT count(*) FROM probe;")
if [ "$PROBE_ROWS" -lt 1 ]; then
    echo "FAIL: probe-ok never fired (0 rows in probe)"
    exit 1
fi
OK_STATUS=$(psqlc -tAc "SELECT status FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname='probe-ok') ORDER BY runid DESC LIMIT 1;")
FAIL_STATUS=$(psqlc -tAc "SELECT status FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname='probe-fail') ORDER BY runid DESC LIMIT 1;")
FAIL_MSG=$(psqlc -tAc "SELECT return_message FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname='probe-fail') ORDER BY runid DESC LIMIT 1;")
if [ "$OK_STATUS" != "succeeded" ]; then
    echo "FAIL: probe-ok's last run_details status was '$OK_STATUS', expected succeeded"
    exit 1
fi
if [ "$FAIL_STATUS" != "failed" ] || [ -z "$FAIL_MSG" ]; then
    echo "FAIL: probe-fail's last run_details was status='$FAIL_STATUS' message='$FAIL_MSG', expected failed with a message"
    exit 1
fi
# The launcher must still be alive and scheduling after a job failure.
LAUNCHER_ALIVE=$(psqlc -tAc "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'pg_cron scheduler';")
if [ "$LAUNCHER_ALIVE" != "1" ]; then
    echo "FAIL: pg_cron launcher is not running after a job failure"
    exit 1
fi

echo "==> Cancellation-as-unschedule: a job removed before its next run must not record one"
psqlc -c "
    CREATE TABLE cancel_probe (id serial primary key);
    SELECT cron.schedule('cancel-me', '* * * * *', \$\$INSERT INTO cancel_probe DEFAULT VALUES\$\$);
"
CANCEL_JOBID=$(psqlc -tAc "SELECT jobid FROM cron.job WHERE jobname = 'cancel-me';")
psqlc -c "SELECT cron.unschedule($CANCEL_JOBID);"
wait_past_minute_boundary 10
CANCEL_RUNS=$(psqlc -tAc "SELECT count(*) FROM cron.job_run_details WHERE jobid = $CANCEL_JOBID;")
if [ "$CANCEL_RUNS" != "0" ]; then
    echo "FAIL: unscheduled job still ran ($CANCEL_RUNS run(s) recorded)"
    exit 1
fi

echo "==> Concurrency: cron.max_running_jobs actually bounds concurrent job workers"
# ALTER SYSTEM refuses to run inside a transaction block, and psql sends a
# multi-statement -c string as a single implicit transaction -- so it needs
# its own -c call, separate from the SELECTs.
psqlc -c "ALTER SYSTEM SET cron.max_running_jobs = 1;"
psqlc -c "
    SELECT pg_reload_conf();
    SELECT cron.schedule('slow-a', '* * * * *', 'SELECT pg_sleep(70)');
    SELECT cron.schedule('slow-b', '* * * * *', 'SELECT pg_sleep(70)');
"
wait_past_minute_boundary 15
CONCURRENT=$(psqlc -tAc "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'pg_cron job';")
if [ "$CONCURRENT" -gt 1 ]; then
    echo "FAIL: $CONCURRENT pg_cron job workers running concurrently, expected at most 1 (cron.max_running_jobs=1)"
    exit 1
fi
if ! docker logs "$CONTAINER" 2>&1 | grep -q 'running-job limit'; then
    echo "FAIL: expected a 'running-job limit reached' warning for the job that could not launch"
    exit 1
fi
psqlc -c "
    SELECT cron.unschedule('slow-a');
    SELECT cron.unschedule('slow-b');
"
psqlc -c "ALTER SYSTEM SET cron.max_running_jobs = DEFAULT;"
psqlc -c "SELECT pg_reload_conf();"

echo "==> Restart/recovery: the launcher must resume scheduling after a container restart"
BEFORE_RESTART=$(psqlc -tAc "SELECT count(*) FROM probe;")
docker restart "$CONTAINER" >/dev/null
wait_ready "$CONTAINER"
wait_past_minute_boundary 10
AFTER_RESTART=$(psqlc -tAc "SELECT count(*) FROM probe;")
if [ "$AFTER_RESTART" -le "$BEFORE_RESTART" ]; then
    echo "FAIL: probe-ok did not fire again after a container restart ($BEFORE_RESTART -> $AFTER_RESTART)"
    exit 1
fi

echo "==> PASS: pg_cron's SQL API, permissions, execution, cancellation, concurrency limit, and restart recovery all behave correctly"
