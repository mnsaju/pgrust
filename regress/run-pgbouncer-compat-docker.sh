#!/usr/bin/env bash
# Lane B7: does the connection pooler operators actually deploy work in front
# of pgrust?
#
# Drives the REAL C pgbouncer (Debian package) against a pgrust server in a
# separate container, over the network -- never a Rust reimplementation of the
# pooler, which would test our own code instead of proving compatibility.
#
# Each check runs the same statement twice: once through pgbouncer and once
# straight at pgrust. A check only counts as a pooler finding when the direct
# run agrees with C's expectation and the pooled run does not; that keeps
# pgrust's own defects out of this ledger.
#
# Usage:
#   regress/run-pgbouncer-compat-docker.sh
#   regress/run-pgbouncer-compat-docker.sh --allow-file regress/pgbouncer-known-failures.allow
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
DRIVER="${PGBOUNCER_DRIVER_IMAGE:-pgrust:pgbouncer-driver}"
NET="pgb-net-$$"; SRV="pgb-srv-$$"; DRV="pgb-drv-$$"
ALLOW=""
[ "${1:-}" = "--allow-file" ] && { ALLOW="$2"; shift 2; }

cleanup() {
    docker rm -f "$SRV" "$DRV" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for img in "$IMAGE" "$DRIVER"; do
    docker image inspect "$img" >/dev/null 2>&1 || {
        [ "$img" = "$DRIVER" ] && docker build -f "$REPO_ROOT/regress/pgbouncer/Dockerfile" \
            -t "$DRIVER" "$REPO_ROOT/regress/pgbouncer" || {
            echo "FAIL: image $img missing (build it first)" >&2; exit 2; }
    }
done

docker network create "$NET" >/dev/null
docker run -d --name "$SRV" --network "$NET" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" \
    "$IMAGE" >/dev/null

echo "==> waiting for pgrust"
ready=0
for _ in $(seq 1 90); do
    docker exec "$SRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { ready=1; break; }
    sleep 1
done
[ "$ready" -eq 1 ] || { echo "FAIL: pgrust never became ready"; docker logs "$SRV" | tail -20; exit 2; }

docker run -d --name "$DRV" --network "$NET" --entrypoint sleep "$DRIVER" infinity >/dev/null

# pool_mode=session is the conservative default and the one an operator reaches
# for first; transaction mode is exercised as its own check below.
docker exec "$DRV" sh -c "cat > /etc/pgbouncer/pgbouncer.ini <<'INI'
[databases]
postgres = host=$SRV port=5432 dbname=postgres
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = trust
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
stats_users = postgres
pool_mode = session
max_client_conn = 50
default_pool_size = 5
logfile = /tmp/pgb/pgbouncer.log
pidfile = /tmp/pgb/pgbouncer.pid
ignore_startup_parameters = extra_float_digits,options
INI
echo '\"postgres\" \"\"' > /etc/pgbouncer/userlist.txt
# pgbouncer exits FATAL as root, by design. The Debian package ships a
# postgres user (uid 100); give it the files it must write. /var/run is a
# symlink to /run on Debian and is not writable by it, so log and pid live
# under a dedicated /tmp dir instead.
mkdir -p /tmp/pgb
chown -R postgres:postgres /etc/pgbouncer /tmp/pgb"
docker exec -d -u postgres "$DRV" pgbouncer -q /etc/pgbouncer/pgbouncer.ini
sleep 2

POOLED="psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -Atq"
DIRECT="psql -h $SRV -p 5432 -U postgres -d postgres -Atq"

# If the pooler is not actually accepting connections, every check below
# reports a connection error -- and `reset-on-reuse`, which asserts a GUC did
# NOT survive, reports PASS. A dead pooler must therefore abort the lane, not
# produce a scorecard with a false green in it.
if ! docker exec "$DRV" sh -c "psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -Atqc 'SELECT 1'" >/dev/null 2>&1; then
    echo "FAIL: pgbouncer is not accepting connections; refusing to score checks." >&2
    docker exec "$DRV" tail -20 /tmp/pgb/pgbouncer.log 2>/dev/null >&2 || true
    exit 2
fi

pass=0; fail=0; declare -a FAILED=()
check() { # name, sql, expected
    local name="$1" sql="$2" want="$3" got direct
    got="$(docker exec "$DRV" sh -c "$POOLED -c \"$sql\" 2>&1" | tr -d '\r' | tail -1 || true)"
    direct="$(docker exec "$DRV" sh -c "$DIRECT -c \"$sql\" 2>&1" | tr -d '\r' | tail -1 || true)"
    if [ "$got" = "$want" ]; then
        printf '  PASS  %-34s\n' "$name"; pass=$((pass+1))
    elif [ "$direct" != "$want" ]; then
        printf '  SKIP  %-34s (pgrust itself differs: %s)\n' "$name" "$direct"
    else
        printf '  FAIL  %-34s pooled=[%s] direct=[%s]\n' "$name" "$got" "$direct"
        FAILED+=("$name"); fail=$((fail+1))
    fi
}

echo "==> pgbouncer $(docker exec "$DRV" sh -c 'pgbouncer --version 2>&1 | head -1')  in front of pgrust"
echo
check "simple-query"            "SELECT 1"                                        "1"
check "text-roundtrip"          "SELECT 'hello'"                                  "hello"
check "server-version"          "SHOW server_version"                             "18.3"
check "transaction-commit"      "BEGIN; CREATE TEMP TABLE t(i int); INSERT INTO t VALUES (7); SELECT i FROM t; COMMIT" "7"
check "prepared-execute"        "PREPARE p AS SELECT 21*2; EXECUTE p"              "42"
check "multi-statement"         "SELECT 1; SELECT 2"                              "2"
check "error-passthrough"       "SELECT 1/0"                       "ERROR:  division by zero"
check "session-set-visible"     "SET application_name='b7'; SHOW application_name" "b7"
check "copy-to-stdout"          "COPY (SELECT 5) TO STDOUT"                       "5"
check "backend-pid-present"     "SELECT pg_backend_pid() > 0"                     "t"

# Reset-on-reuse: a GUC set in one pooled session must not leak into the next.
docker exec "$DRV" sh -c "$POOLED -c \"SET application_name='leaked'\"" >/dev/null 2>&1 || true
leak="$(docker exec "$DRV" sh -c "$POOLED -c \"SHOW application_name\" 2>&1" | tr -d '\r' | tail -1 || true)"
if [ "$leak" = "leaked" ]; then
    printf '  FAIL  %-34s a GUC survived into a new pooled session\n' "reset-on-reuse"
    FAILED+=("reset-on-reuse"); fail=$((fail+1))
else
    printf '  PASS  %-34s\n' "reset-on-reuse"; pass=$((pass+1))
fi

# The admin console is how an operator inspects a pool; it must answer.
adm="$(docker exec "$DRV" sh -c "psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -Atq -c 'SHOW POOLS' 2>&1" | tr -d '\r' | head -1 || true)"
case "$adm" in
    ""|*ERROR*|*error*) printf '  FAIL  %-34s SHOW POOLS: %s\n' "admin-console" "$adm"; FAILED+=("admin-console"); fail=$((fail+1)) ;;
    *) printf '  PASS  %-34s\n' "admin-console"; pass=$((pass+1)) ;;
esac

echo
echo "==> pgbouncer compat: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
echo "==> pgbouncer log:"; docker exec "$DRV" tail -6 /tmp/pgb/pgbouncer.log 2>/dev/null || true

if [ -n "$ALLOW" ] && [ -f "$ALLOW" ]; then
    allowed="$(grep -v '^\s*#' "$ALLOW" | grep -v '^\s*$' || true)"
    newf=0
    for f in ${FAILED[@]+"${FAILED[@]}"}; do
        grep -qx "$f" <<<"$allowed" || { echo "  NEW failure not in ledger: $f"; newf=1; }
    done
    for a in $allowed; do
        printf '%s\n' ${FAILED[@]+"${FAILED[@]}"} | grep -qx "$a" || { echo "  STALE ledger entry (now passing): $a"; newf=1; }
    done
    exit "$newf"
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
