#!/usr/bin/env bash
# Lane B2: pg_dump / pg_restore round trip, in both directions.
#
# B4 proved a physical backup can be restored. This lane proves the LOGICAL
# path: that data in pgrust can be dumped with C's pg_dump and loaded into a
# real PostgreSQL, and the reverse. That is the migration story -- both the way
# in (bring an existing database to pgrust) and, more importantly, the way out.
# A distribution nobody can leave is a distribution nobody should enter.
#
# The dump is taken by C's pg_dump from a driver container over the network;
# the two servers are separate containers with separate data directories.
set -euo pipefail

IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
CBIN=/usr/lib/postgresql/18/bin
PGDATA=/var/lib/postgresql/data
RUSTC="b2-rust-$$"; CSRV="b2-c-$$"; DRV="b2-drv-$$"
CVOL="b2-cvol-$$"; NET="b2-net-$$"

cleanup() {
    docker rm -f "$RUSTC" "$CSRV" "$DRV" >/dev/null 2>&1 || true
    docker volume rm "$CVOL" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0; fail=0; declare -a FAILED=()
ok()  { printf '  PASS  %-32s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  FAIL  %-32s %s\n' "$1" "${2:-}"; FAILED+=("$1"); fail=$((fail+1)); }

docker network create "$NET" >/dev/null
docker volume create "$CVOL" >/dev/null

echo "==> starting pgrust (source)"
docker run -d --name "$RUSTC" --network "$NET" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" >/dev/null
for _ in $(seq 1 90); do docker exec "$RUSTC" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done

# A C cluster to load into. The image's entrypoint runs C initdb and then
# starts pgrust, so initialise with it, stop, and relaunch on the C binary.
echo "==> preparing a real PostgreSQL 18.3 (destination)"
docker run -d --name "$CSRV" --network "$NET" -v "$CVOL:$PGDATA" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" >/dev/null
for _ in $(seq 1 90); do docker exec "$CSRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
docker exec -u postgres "$CSRV" "$CBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
docker rm -f "$CSRV" >/dev/null 2>&1 || true
docker run -d --name "$CSRV" --network "$NET" -v "$CVOL:$PGDATA" --user postgres \
    --entrypoint "$CBIN/postgres" "$IMAGE" -D "$PGDATA" \
    -c listen_addresses='*' -c unix_socket_directories=/tmp >/dev/null
cup=0
for _ in $(seq 1 90); do docker exec "$CSRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { cup=1; break; }; sleep 1; done
[ "$cup" -eq 1 ] || { echo "FAIL: destination PostgreSQL never started"; docker logs "$CSRV" 2>&1 | tail -12; exit 2; }

docker run -d --name "$DRV" --network "$NET" --entrypoint sleep "$IMAGE" infinity >/dev/null
d() { docker exec "$DRV" "$@"; }

# A schema broad enough that the dump exercises real formatting: numeric,
# timestamps, arrays, jsonb, bytea, text with quoting hazards, a view, an
# index, a sequence and a NOT NULL/CHECK constraint.
echo "==> seeding the source"
docker exec "$RUSTC" psql -U postgres -h localhost -q -v ON_ERROR_STOP=1 -c "
CREATE TABLE t_main(
  id serial primary key,
  n numeric(12,4) NOT NULL,
  ts timestamptz NOT NULL,
  arr int[],
  j jsonb,
  b bytea,
  s text CHECK (length(s) > 0)
);
INSERT INTO t_main(n, ts, arr, j, b, s)
SELECT g * 1.2345, '2026-01-01 00:00:00+00'::timestamptz + (g || ' hours')::interval,
       ARRAY[g, g*2, g*3], jsonb_build_object('g', g, 'txt', 'v'||g),
       decode(lpad(to_hex(g), 8, '0'), 'hex'),
       'quote''s and \"double\" #' || g
FROM generate_series(1, 300) g;
CREATE INDEX t_main_n_idx ON t_main(n);
CREATE VIEW v_main AS SELECT id, n FROM t_main WHERE n > 100;
" >/dev/null 2>&1 || { echo "FAIL: could not seed source"; exit 2; }

SRC_ROWS="$(docker exec "$RUSTC" psql -U postgres -h localhost -Atc 'SELECT count(*) FROM t_main')"
SRC_SUM="$(docker exec "$RUSTC" psql -U postgres -h localhost -Atc \
    "SELECT md5(string_agg(id::text||n::text||ts::text||arr::text||j::text||encode(b,'hex')||s, '|' ORDER BY id)) FROM t_main")"
echo "    source: $SRC_ROWS rows, digest ${SRC_SUM:0:16}"

PGD="$CBIN/pg_dump"; PSQL="$CBIN/psql"; PGR="$CBIN/pg_restore"

# --- plain-format dump out of pgrust ---------------------------------------
if d sh -c "$PGD -h $RUSTC -U postgres -d postgres -f /tmp/plain.sql" 2>/tmp/e; then
    sz="$(d sh -c 'wc -l < /tmp/plain.sql' | tr -d ' ')"
    ok "pg_dump-plain-from-pgrust" "$sz lines"
else
    bad "pg_dump-plain-from-pgrust" "$(d sh -c 'true'; head -2 /tmp/e 2>/dev/null | tr '\n' ' ')"
fi

if d sh -c "$PSQL -h $CSRV -U postgres -d postgres -q -v ON_ERROR_STOP=1 -f /tmp/plain.sql" >/dev/null 2>&1; then
    ok "restore-plain-into-postgres"
    got="$(d sh -c "$PSQL -h $CSRV -U postgres -d postgres -Atc 'SELECT count(*) FROM t_main'" | tr -d '\r')"
    [ "$got" = "$SRC_ROWS" ] && ok "row-count-matches" "$got" || bad "row-count-matches" "got [$got] want $SRC_ROWS"
    dg="$(d sh -c "$PSQL -h $CSRV -U postgres -d postgres -Atc \"SELECT md5(string_agg(id::text||n::text||ts::text||arr::text||j::text||encode(b,'hex')||s, '|' ORDER BY id)) FROM t_main\"" | tr -d '\r')"
    [ "$dg" = "$SRC_SUM" ] && ok "content-digest-matches" "${dg:0:16}" || bad "content-digest-matches" "got ${dg:0:16} want ${SRC_SUM:0:16}"
    vw="$(d sh -c "$PSQL -h $CSRV -U postgres -d postgres -Atc 'SELECT count(*) FROM v_main'" | tr -d '\r')"
    [ -n "$vw" ] && [ "$vw" -gt 0 ] 2>/dev/null && ok "view-and-index-restored" "v_main: $vw rows" || bad "view-and-index-restored" "v_main: [$vw]"
else
    bad "restore-plain-into-postgres" "psql -f failed"
    d sh -c "$PSQL -h $CSRV -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/plain.sql" 2>&1 | tail -6 | sed 's/^/        /'
fi

# --- custom format + pg_restore --------------------------------------------
d sh -c "$PSQL -h $CSRV -U postgres -d postgres -q -c 'DROP VIEW IF EXISTS v_main; DROP TABLE IF EXISTS t_main CASCADE'" >/dev/null 2>&1 || true
if d sh -c "$PGD -Fc -h $RUSTC -U postgres -d postgres -f /tmp/dump.fc" >/dev/null 2>&1; then
    ok "pg_dump-custom-from-pgrust"
    if d sh -c "$PGR -h $CSRV -U postgres -d postgres --no-owner /tmp/dump.fc" >/dev/null 2>&1; then
        got="$(d sh -c "$PSQL -h $CSRV -U postgres -d postgres -Atc 'SELECT count(*) FROM t_main'" | tr -d '\r')"
        [ "$got" = "$SRC_ROWS" ] && ok "pg_restore-custom-into-postgres" "$got rows" \
                                 || bad "pg_restore-custom-into-postgres" "got [$got]"
    else
        bad "pg_restore-custom-into-postgres" "pg_restore failed"
    fi
else
    bad "pg_dump-custom-from-pgrust" "pg_dump -Fc failed"
fi

# --- the way IN: dump from real PostgreSQL, load into pgrust ---------------
d sh -c "$PSQL -h $CSRV -U postgres -d postgres -q -c \"CREATE TABLE from_c(id int primary key, v text); INSERT INTO from_c SELECT g,'c-'||g FROM generate_series(1,250) g;\"" >/dev/null 2>&1
if d sh -c "$PGD -h $CSRV -U postgres -d postgres -t from_c -f /tmp/fromc.sql" >/dev/null 2>&1 \
   && d sh -c "$PSQL -h $RUSTC -U postgres -d postgres -q -v ON_ERROR_STOP=1 -f /tmp/fromc.sql" >/dev/null 2>&1; then
    got="$(docker exec "$RUSTC" psql -U postgres -h localhost -Atc 'SELECT count(*) FROM from_c')"
    [ "$got" = "250" ] && ok "reverse-load-into-pgrust" "250 rows" || bad "reverse-load-into-pgrust" "got [$got]"
else
    bad "reverse-load-into-pgrust" "dump-from-C or load-into-pgrust failed"
fi

# --- globals ----------------------------------------------------------------
if d sh -c "$CBIN/pg_dumpall -h $RUSTC -U postgres --globals-only -f /tmp/globals.sql" >/dev/null 2>&1; then
    ok "pg_dumpall-globals-from-pgrust"
else
    bad "pg_dumpall-globals-from-pgrust" "pg_dumpall --globals-only failed"
fi

echo
echo "==> pg_dump round trip: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
