#!/usr/bin/env bash
# Lane B3: pg_basebackup, pg_verifybackup, and booting the result.
#
# Distinct from B4 (pgBackRest) in what it exercises: pg_basebackup takes a
# REPLICATION connection and streams the base backup over the wire, so this
# lane tests the walsender path, the backup manifest, and -X stream WAL
# collection -- none of which the filesystem-level pgBackRest path touches.
# It is also the tool most operators reach for first, and what almost every
# "make me a standby" runbook is built on.
set -euo pipefail

IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
CBIN=/usr/lib/postgresql/18/bin
PGDATA=/var/lib/postgresql/data
SRV="b3-srv-$$"; DRV="b3-drv-$$"; BOOT="b3-boot-$$"
BKVOL="b3-bk-$$"; NET="b3-net-$$"

cleanup() {
    docker rm -f "$SRV" "$DRV" "$BOOT" >/dev/null 2>&1 || true
    docker volume rm "$BKVOL" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0; fail=0; declare -a FAILED=()
ok()  { printf '  PASS  %-32s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  FAIL  %-32s %s\n' "$1" "${2:-}"; FAILED+=("$1"); fail=$((fail+1)); }

docker network create "$NET" >/dev/null
docker volume create "$BKVOL" >/dev/null

echo "==> starting pgrust with replication enabled"
docker run -d --name "$SRV" --network "$NET" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" \
    -c wal_level=replica -c max_wal_senders=4 -c max_replication_slots=4 >/dev/null
up=0
for _ in $(seq 1 90); do docker exec "$SRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[ "$up" -eq 1 ] || { echo "FAIL: pgrust never became ready"; docker logs "$SRV" 2>&1 | tail -15; exit 2; }

docker exec "$SRV" psql -U postgres -h localhost -q -c \
    "CREATE TABLE bb(id int primary key, v text);
     INSERT INTO bb SELECT g,'base-'||g FROM generate_series(1,700) g;" >/dev/null

# pg_basebackup must write as the uid that will later boot the directory, so
# the volume is handed to postgres (999) by a throwaway root container first.
docker run --rm -v "$BKVOL:/backup" --entrypoint sh "$IMAGE" \
    -c 'rm -rf /backup/* /backup/.[!.]* 2>/dev/null; mkdir -p /backup/plain /backup/tar; chown -R postgres:postgres /backup' >/dev/null
docker run -d --name "$DRV" --network "$NET" -v "$BKVOL:/backup" \
    --user postgres --entrypoint sleep "$IMAGE" infinity >/dev/null
d() { docker exec "$DRV" "$@"; }

# initdb writes replication trust lines for 127.0.0.1 only, and the entrypoint's
# catch-all `host all all all trust` deliberately does NOT cover them: in
# PostgreSQL the `replication` keyword is matched only by an explicit
# replication entry, while `replication=database` (logical) matches ordinary
# database entries instead. pgrust reproduces both halves of that, so a
# physical basebackup from another host needs the line an operator would add.
docker exec "$SRV" sh -c \
    "grep -q '^host *replication *all *all' $PGDATA/pg_hba.conf || \
     echo 'host replication all all trust' >> $PGDATA/pg_hba.conf"
docker exec "$SRV" psql -U postgres -h localhost -q -c 'SELECT pg_reload_conf()' >/dev/null

# A replication connection is the precondition for everything below; if it is
# refused, say so once rather than reporting five derived failures.
echo "==> checking the replication connection"
if d sh -c "$CBIN/psql 'host=$SRV user=postgres dbname=postgres replication=database' -Atc 'IDENTIFY_SYSTEM'" >/tmp/ident 2>&1; then
    ok "replication-connection" "$(head -1 /tmp/ident | cut -c1-46)"
else
    bad "replication-connection" "$(d sh -c "$CBIN/psql 'host=$SRV user=postgres dbname=postgres replication=database' -Atc 'IDENTIFY_SYSTEM'" 2>&1 | tr '\n' ' ' | cut -c1-150)"
fi

echo "==> pg_basebackup"
if d sh -c "$CBIN/pg_basebackup -h $SRV -U postgres -D /backup/plain -X stream -P --no-password" >/tmp/bb 2>&1; then
    ok "pg_basebackup-plain-Xstream" "$(d sh -c 'du -sh /backup/plain 2>/dev/null | cut -f1')"
else
    bad "pg_basebackup-plain-Xstream" "$(d sh -c "$CBIN/pg_basebackup -h $SRV -U postgres -D /backup/plain2 -X stream --no-password" 2>&1 | tr '\n' ' ' | cut -c1-170)"
fi

if d sh -c "$CBIN/pg_basebackup -h $SRV -U postgres -D /backup/tar -Ft -z -X fetch --no-password" >/dev/null 2>&1; then
    ok "pg_basebackup-tar-gz" "$(d sh -c 'ls /backup/tar | tr "\n" " "')"
else
    bad "pg_basebackup-tar-gz" "tar/gzip format backup failed"
fi

if d test -f /backup/plain/backup_manifest; then
    ok "backup-manifest-present"
    if d sh -c "$CBIN/pg_verifybackup /backup/plain" >/tmp/vb 2>&1; then
        ok "pg_verifybackup"
    else
        bad "pg_verifybackup" "$(d sh -c "$CBIN/pg_verifybackup /backup/plain" 2>&1 | tr '\n' ' ' | cut -c1-170)"
    fi
else
    bad "backup-manifest-present" "no backup_manifest written"
fi

echo "==> booting the base backup in a separate container"
if d test -f /backup/plain/PG_VERSION; then
    docker run -d --name "$BOOT" --network "$NET" -v "$BKVOL:/bk" \
        -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
        -e PGDATA=/bk/plain "$IMAGE" >/dev/null 2>&1 || true
    bup=0
    for _ in $(seq 1 90); do docker exec "$BOOT" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { bup=1; break; }; sleep 1; done
    if [ "$bup" -eq 1 ]; then
        got="$(docker exec "$BOOT" psql -U postgres -h localhost -Atc 'SELECT count(*) FROM bb' 2>&1 | tail -1)"
        [ "$got" = "700" ] && ok "basebackup-boots-data-intact" "700 rows" \
                           || bad "basebackup-boots-data-intact" "count(*)=[$got] expected 700"
    else
        bad "basebackup-boots-data-intact" "backup directory did not boot"
        docker logs "$BOOT" 2>&1 | tail -12 | sed 's/^/        /'
    fi
else
    bad "basebackup-boots-data-intact" "no backup to boot"
fi

echo
echo "==> pg_basebackup: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
