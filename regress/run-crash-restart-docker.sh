#!/usr/bin/env bash
# Lane B5: unclean crash, restart, and what survived.
#
# This lane is shaped by a fact established in lane A1. pgrust is
# thread-per-backend and allocates a SYNTHETIC pid space (pg_stat_activity
# shows 1000, 1001, 1029, ...; /proc/<pid> does not exist for any of them),
# because there are no per-backend processes to have OS pids. Upstream's
# 013_crash_restart signals pg_backend_pid() from outside and therefore cannot
# reach its subject here -- `kill -QUIT $(pg_backend_pid())` returns ESRCH.
#
# The consequence is not that crash behaviour is untestable, but that the unit
# of crash is different: in this architecture a fatal signal takes the whole
# server, so the whole server is what must be crashed. That is also the honest
# durability question for a published distribution -- kill -9 the process,
# start it again, and account for exactly what survived.
#
# Backend-level termination is still checked, through the SQL surface that
# does work here (pg_cancel_backend / pg_terminate_backend).
set -euo pipefail

IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
PGDATA=/var/lib/postgresql/data
CBIN=/usr/lib/postgresql/18/bin
VOL="b5-vol-$$"; SRV="b5-srv-$$"
CYCLES="${CRASH_CYCLES:-3}"

cleanup() { docker rm -f "$SRV" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

pass=0; fail=0; declare -a FAILED=()
ok()  { printf '  PASS  %-34s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  FAIL  %-34s %s\n' "$1" "${2:-}"; FAILED+=("$1"); fail=$((fail+1)); }

start() {
    docker rm -f "$SRV" >/dev/null 2>&1 || true
    docker run -d --name "$SRV" -v "$VOL:$PGDATA" \
        -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
        -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" >/dev/null
    for _ in $(seq 1 90); do
        docker exec "$SRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
q() { docker exec "$SRV" psql -U postgres -h localhost -Atc "$1" 2>&1 | tail -1; }

docker volume create "$VOL" >/dev/null
echo "==> initial boot"
start || { echo "FAIL: could not start"; docker logs "$SRV" 2>&1 | tail -12; exit 2; }
docker exec "$SRV" psql -U postgres -h localhost -q -c \
    "CREATE TABLE durable(id int primary key, v text);
     CREATE TABLE ghost(id int primary key);" >/dev/null

# ---------------------------------------------------------------------------
# Backend termination through the surface that exists here
# ---------------------------------------------------------------------------
echo
echo "== backend termination (SQL surface) =="
docker exec -d "$SRV" psql -U postgres -h localhost -c "SELECT pg_sleep(120)" >/dev/null 2>&1
sleep 3
victim="$(q "SELECT pid FROM pg_stat_activity WHERE query LIKE '%pg_sleep(120)%' AND pid <> pg_backend_pid() LIMIT 1")"
if [ -n "$victim" ] && [ "$victim" -eq "$victim" ] 2>/dev/null; then
    ok "victim-backend-visible" "pid $victim in pg_stat_activity"
    res="$(q "SELECT pg_cancel_backend($victim)")"
    [ "$res" = "t" ] && ok "pg_cancel_backend" || bad "pg_cancel_backend" "returned [$res]"
    sleep 2
    res="$(q "SELECT pg_terminate_backend($victim)")"
    case "$res" in t|f) ok "pg_terminate_backend" "returned $res" ;; *) bad "pg_terminate_backend" "[$res]" ;; esac
    sleep 2
    left="$(q "SELECT count(*) FROM pg_stat_activity WHERE pid = $victim")"
    [ "$left" = "0" ] && ok "victim-gone-after-terminate" || bad "victim-gone-after-terminate" "still present"
else
    bad "victim-backend-visible" "could not find the sleeping backend"
fi
alive="$(q 'SELECT 1')"
[ "$alive" = "1" ] && ok "server-alive-after-terminate" || bad "server-alive-after-terminate" "[$alive]"

# ---------------------------------------------------------------------------
# Crash cycles
# ---------------------------------------------------------------------------
echo
echo "== $CYCLES kill -9 crash cycles =="
committed=0
for c in $(seq 1 "$CYCLES"); do
    lo=$(( committed + 1 )); hi=$(( committed + 400 ))
    docker exec "$SRV" psql -U postgres -h localhost -q -c \
        "INSERT INTO durable SELECT g,'c'||g FROM generate_series($lo,$hi) g;" >/dev/null
    committed=$hi

    # An uncommitted writer, deliberately still open when the server dies.
    docker exec -d "$SRV" psql -U postgres -h localhost -c \
        "BEGIN; INSERT INTO ghost SELECT g FROM generate_series(1,50) g; SELECT pg_sleep(120);" >/dev/null 2>&1
    sleep 2

    docker kill -s KILL "$SRV" >/dev/null 2>&1 || true
    if ! start; then
        bad "cycle$c-restart" "did not come back after kill -9"
        docker logs "$SRV" 2>&1 | tail -14 | sed 's/^/        /'
        break
    fi

    got="$(q 'SELECT count(*) FROM durable')"
    if [ "$got" = "$committed" ]; then
        ok "cycle$c-committed-survived" "$got rows"
    else
        bad "cycle$c-committed-survived" "count(*)=[$got] expected $committed"
    fi
    gh="$(q 'SELECT count(*) FROM ghost')"
    [ "$gh" = "0" ] && ok "cycle$c-uncommitted-discarded" \
                    || bad "cycle$c-uncommitted-discarded" "ghost has [$gh] rows, expected 0"

    if docker logs "$SRV" 2>&1 | grep -qiE "redo|recovery|starting backup recovery|database system was not properly shut down"; then
        ok "cycle$c-recovery-ran" "$(docker logs "$SRV" 2>&1 | grep -iE 'not properly shut down|redo (starts|done)' | head -1 | sed 's/.*LOG: *//' | cut -c1-46)"
    else
        bad "cycle$c-recovery-ran" "no recovery evidence in the log after an unclean kill"
    fi
done

# Integrity after the last crash: the index and the heap must still agree.
idx="$(q 'SET enable_seqscan=off; SELECT count(*) FROM durable WHERE id > 0')"
seq="$(q 'SET enable_seqscan=on;  SELECT count(*) FROM durable WHERE id > 0')"
if [ "$idx" = "$seq" ] && [ "$idx" = "$committed" ]; then
    ok "index-and-heap-agree" "$idx via both paths"
else
    bad "index-and-heap-agree" "index=[$idx] seq=[$seq] expected $committed"
fi

state="$(docker exec "$SRV" "$CBIN/pg_controldata" -D "$PGDATA" 2>/dev/null | grep -i 'cluster state' | tr -s ' ' || true)"
[ -n "$state" ] && ok "pg_controldata-after-crash" "$state" || bad "pg_controldata-after-crash" "no cluster state reported"

echo
echo "==> crash/restart: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
