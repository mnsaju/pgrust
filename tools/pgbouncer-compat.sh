#!/usr/bin/env bash
# Verify pgrust's server-reset contract through a real PgBouncer transaction
# pool.  This intentionally drives the public PostgreSQL wire protocol: it is
# a compatibility test, not a pgrust-internal pooling test.
set -euo pipefail

: "${PGRUST_BIN:?set PGRUST_BIN to the pgrust postgres binary}"
: "${PGRUST_PGSHAREDIR:?set PGRUST_PGSHAREDIR as in the pgrust quickstart}"
: "${PGRUST_TZDIR:?set PGRUST_TZDIR as in the pgrust quickstart}"

INITDB="${INITDB:-initdb}"
PSQL="${PSQL:-psql}"
PGBOUNCER="${PGBOUNCER:-pgbouncer}"
PORT_BASE="${PGRUST_TEST_PORT:-$((20000 + ($$ % 20000)))}"
PGRUST_PORT="$PORT_BASE"
PGBOUNCER_PORT="$((PORT_BASE + 1))"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pgrust-pgbouncer.XXXXXX")"
DATA="$WORKDIR/data"
PGRUST_PID=""
PGBOUNCER_PID=""

cleanup() {
    if [[ -n "$PGBOUNCER_PID" ]]; then
        kill "$PGBOUNCER_PID" 2>/dev/null || true
        wait "$PGBOUNCER_PID" 2>/dev/null || true
    fi
    if [[ -n "$PGRUST_PID" ]]; then
        kill -INT "$PGRUST_PID" 2>/dev/null || true
        wait "$PGRUST_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

pool_psql() {
    "$PSQL" -X -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U postgres -d postgres "$@"
}

direct_psql() {
    "$PSQL" -X -h 127.0.0.1 -p "$PGRUST_PORT" -U postgres -d postgres "$@"
}

wait_for() {
    local label="$1"
    local tries=100
    until "$@" >/dev/null 2>&1; do
        tries=$((tries - 1))
        if (( tries == 0 )); then
            echo "timed out waiting for $label" >&2
            return 1
        fi
        sleep 0.1
    done
}

"$INITDB" -D "$DATA" --no-locale --encoding=UTF8 -U postgres >/dev/null
"$PGRUST_BIN" -D "$DATA" -p "$PGRUST_PORT" \
    -c listen_addresses=127.0.0.1 \
    -c io_method=sync \
    -c max_stack_depth=60000 \
    >"$WORKDIR/pgrust.log" 2>&1 &
PGRUST_PID=$!
wait_for pgrust direct_psql -Atqc 'SELECT 1'

cat >"$WORKDIR/pgbouncer.ini" <<EOF
[databases]
postgres = host=127.0.0.1 port=$PGRUST_PORT dbname=postgres

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBOUNCER_PORT
auth_type = trust
pool_mode = transaction
server_reset_query = DISCARD ALL
pidfile = $WORKDIR/pgbouncer.pid
logfile = $WORKDIR/pgbouncer.log
EOF

"$PGBOUNCER" "$WORKDIR/pgbouncer.ini" >"$WORKDIR/pgbouncer.stdout" 2>&1 &
PGBOUNCER_PID=$!
wait_for PgBouncer pool_psql -Atqc 'SELECT 1'

baseline_work_mem="$(pool_psql -Atqc 'SHOW work_mem')"
pool_psql -v ON_ERROR_STOP=1 -c "SET work_mem = '1MB'; PREPARE pgbouncer_reset_plan AS SELECT 1; CREATE TEMP TABLE pgbouncer_reset_temp (id integer); SELECT pg_advisory_lock(424242);" >/dev/null

if [[ "$(pool_psql -Atqc 'SHOW work_mem')" != "$baseline_work_mem" ]]; then
    echo 'PgBouncer reset leaked work_mem into the next client' >&2
    exit 1
fi

if pool_psql -v ON_ERROR_STOP=1 -c 'EXECUTE pgbouncer_reset_plan' >/dev/null 2>&1; then
    echo 'PgBouncer reset leaked a prepared statement into the next client' >&2
    exit 1
fi

if [[ "$(pool_psql -Atqc "SELECT to_regclass('pg_temp.pgbouncer_reset_temp') IS NULL")" != 't' ]]; then
    echo 'PgBouncer reset leaked a temporary table into the next client' >&2
    exit 1
fi

if [[ "$(direct_psql -Atqc 'SELECT pg_try_advisory_lock(424242)')" != 't' ]]; then
    echo 'PgBouncer reset leaked a session advisory lock' >&2
    exit 1
fi
direct_psql -Atqc 'SELECT pg_advisory_unlock(424242)' >/dev/null

echo "PgBouncer transaction-pooling reset contract passed (ports $PGRUST_PORT/$PGBOUNCER_PORT)."
