#!/usr/bin/env bash
# Lane B1: initdb, and the C<->pgrust on-disk interoperability claim.
#
# GOAL.md states the goal as "same on-disk format (a C 18.3 binary can boot our
# data directory and vice versa)". That claim has never been executed. It is
# also the claim a distribution leans on hardest: it is the escape hatch if
# pgrust cannot start, and the reason C's tooling can be the backup story at
# all. This lane boots ONE data directory alternately with each binary and
# checks the data survives the crossing in both directions.
#
# Both binaries live in the image already -- pgrust at /usr/local/bin/pgrust-postgres
# and C 18.3 at /usr/lib/postgresql/18/bin/postgres -- so the two servers are
# genuinely the same bytes on disk, not a copy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
DATAVOL="interop-data-$$"; R="interop-rust-$$"; C="interop-c-$$"
PGDATA=/var/lib/postgresql/data
CBIN=/usr/lib/postgresql/18/bin

cleanup() {
    docker rm -f "$R" "$C" >/dev/null 2>&1 || true
    docker volume rm "$DATAVOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0; fail=0; declare -a FAILED=()
ok()   { printf '  PASS  %-32s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %-32s %s\n' "$1" "${2:-}"; FAILED+=("$1"); fail=$((fail+1)); }

wait_up() { # container
    for _ in $(seq 1 90); do
        docker exec "$1" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

magic() { # container -> first 4 bytes of pg_internal.init, hex, or "absent"
    docker exec "$1" sh -c \
        "test -f $PGDATA/global/pg_internal.init && od -An -tx1 -N4 $PGDATA/global/pg_internal.init | tr -d ' \n' || echo absent"
}

docker volume create "$DATAVOL" >/dev/null

# --- 1. C initdb, pgrust boots it ------------------------------------------
echo "==> C initdb, then pgrust boots the result"
docker run -d --name "$R" -v "$DATAVOL:$PGDATA" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" >/dev/null
if wait_up "$R"; then
    ok "c-initdb-pgrust-boots" "$(docker exec "$R" psql -U postgres -h localhost -Atc 'SELECT version()' | cut -c1-38)"
else
    bad "c-initdb-pgrust-boots" "never became ready"; docker logs "$R" 2>&1 | tail -12; exit 1
fi

docker exec "$R" psql -U postgres -h localhost -q -c \
    "CREATE TABLE interop(id int primary key, who text);
     INSERT INTO interop SELECT g,'written-by-pgrust' FROM generate_series(1,500) g;" >/dev/null
RUST_MAGIC="$(magic "$R")"
echo "    pg_internal.init magic after pgrust: $RUST_MAGIC"

# Clean shutdown; an unclean one would test crash recovery, which is lane B5.
docker exec -u postgres "$R" "$CBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || docker stop -t 30 "$R" >/dev/null
docker rm -f "$R" >/dev/null 2>&1 || true

# --- 2. C reads what pgrust wrote ------------------------------------------
echo "==> C PostgreSQL 18.3 boots the same data directory"
docker run -d --name "$C" -v "$DATAVOL:$PGDATA" --user postgres \
    --entrypoint "$CBIN/postgres" "$IMAGE" \
    -D "$PGDATA" -c listen_addresses=localhost -c unix_socket_directories=/tmp >/dev/null

cq() { docker exec "$C" psql -U postgres -h localhost -Atc "$1" 2>&1 | tail -1; }
cup=0
for _ in $(seq 1 90); do docker exec "$C" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { cup=1; break; }; sleep 1; done

if [ "$cup" -eq 1 ]; then
    ok "c-boots-pgrust-datadir" "$(cq 'SELECT version()' | cut -c1-38)"
    got="$(cq 'SELECT count(*) FROM interop')"
    [ "$got" = "500" ] && ok "c-reads-pgrust-rows" "500 rows" \
                       || bad "c-reads-pgrust-rows" "count(*)=[$got] expected 500"
    # C must REJECT pgrust's init file (different magic) and rebuild it, rather
    # than misreading a foreign layout as its own.
    CMAGIC="$(magic "$C")"
    echo "    pg_internal.init magic after C:      $CMAGIC"
    if [ "$RUST_MAGIC" = "absent" ]; then
        bad "relcache-initfile-magic" "pgrust wrote no init file to test against"
    elif [ "$CMAGIC" = "$RUST_MAGIC" ]; then
        bad "relcache-initfile-magic" "C left pgrust's magic in place; it may have misread it"
    else
        ok "relcache-initfile-magic" "C rejected pgrust's magic and rebuilt"
    fi
    docker exec "$C" psql -U postgres -h localhost -q -c \
        "INSERT INTO interop SELECT g,'written-by-c' FROM generate_series(501,800) g;" >/dev/null 2>&1 \
        && ok "c-writes-to-pgrust-datadir" || bad "c-writes-to-pgrust-datadir" "insert failed"
    docker exec -u postgres "$C" "$CBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || docker stop -t 30 "$C" >/dev/null
else
    bad "c-boots-pgrust-datadir" "C never became ready"
    docker logs "$C" 2>&1 | tail -14 | sed 's/^/        /'
fi
docker rm -f "$C" >/dev/null 2>&1 || true

# --- 3. pgrust reads what C wrote ------------------------------------------
echo "==> pgrust boots it back, after C has written to it"
docker run -d --name "$R" -v "$DATAVOL:$PGDATA" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
if wait_up "$R"; then
    ok "pgrust-reboots-after-c"
    got="$(docker exec "$R" psql -U postgres -h localhost -Atc 'SELECT count(*) FROM interop' 2>&1 | tail -1)"
    [ "$got" = "800" ] && ok "pgrust-reads-c-rows" "800 rows (500 pgrust + 300 C)" \
                       || bad "pgrust-reads-c-rows" "count(*)=[$got] expected 800"
    ctrl="$(docker exec "$R" "$CBIN/pg_controldata" -D "$PGDATA" 2>&1 | grep -i 'catalog version' | head -1 || true)"
    [ -n "$ctrl" ] && ok "pg_controldata-readable" "$(echo "$ctrl" | tr -s ' ')" \
                   || bad "pg_controldata-readable" "pg_controldata produced nothing"
else
    bad "pgrust-reboots-after-c" "never became ready"
    docker logs "$R" 2>&1 | tail -14 | sed 's/^/        /'
fi

echo
echo "==> interop: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
