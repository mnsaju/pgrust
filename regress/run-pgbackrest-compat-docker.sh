#!/usr/bin/env bash
# Lane B4: can a pgrust cluster be backed up and restored with the tool real
# operators use?
#
# Drives the REAL C pgBackRest, never a port. This is the lane that decides
# whether anyone can safely put data in a published pgrust image: a
# distribution whose users cannot get their data back out has no scope in which
# it is safe.
#
# Topology. pgbackrest reads PGDATA directly and its archive_command runs on
# the database host, so it is installed alongside the server -- as operators
# deploy it -- rather than in a pure network driver. The verification half runs
# in a SEPARATELY SPAWNED container that boots the restored data directory, so
# the thing under test never certifies itself.
#
# Usage: regress/run-pgbackrest-compat-docker.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGBACKREST_IMAGE:-pgrust:pgbackrest}"
SRV="pgbr-srv-$$"; VERIFY="pgbr-verify-$$"
REPOVOL="pgbr-repo-$$"; DATAVOL="pgbr-data-$$"; RESTVOL="pgbr-rest-$$"
STANZA=main

cleanup() {
    docker rm -f "$SRV" "$VERIFY" >/dev/null 2>&1 || true
    docker volume rm "$REPOVOL" "$DATAVOL" "$RESTVOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    docker build --build-arg BASE="${PGRUST_IMAGE:-pgrust:pinned}" \
        -f "$REPO_ROOT/regress/pgbackrest/Dockerfile" -t "$IMAGE" "$REPO_ROOT/regress/pgbackrest"; }

pass=0; fail=0; declare -a FAILED=()
step() { # name, command...
    local name="$1"; shift
    if out="$("$@" 2>&1)"; then
        printf '  PASS  %-30s\n' "$name"; pass=$((pass+1)); return 0
    else
        printf '  FAIL  %-30s %s\n' "$name" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        FAILED+=("$name"); fail=$((fail+1)); return 1
    fi
}

docker volume create "$REPOVOL" >/dev/null; docker volume create "$DATAVOL" >/dev/null
docker volume create "$RESTVOL" >/dev/null

echo "==> starting pgrust with archiving on, pgbackrest as the archive_command"
docker run -d --name "$SRV" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" \
    -v "$DATAVOL:/var/lib/postgresql/data" -v "$REPOVOL:/var/lib/pgbackrest" \
    "$IMAGE" \
    -c archive_mode=on \
    -c "archive_command=pgbackrest --stanza=$STANZA archive-push %p" \
    -c wal_level=replica >/dev/null

ready=0
for _ in $(seq 1 90); do
    docker exec "$SRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { ready=1; break; }
    sleep 1
done
[ "$ready" -eq 1 ] || { echo "FAIL: pgrust never became ready"; docker logs "$SRV" 2>&1 | tail -25; exit 2; }
echo "    pgrust: $(docker exec "$SRV" psql -U postgres -h localhost -Atc 'SELECT version()')"
echo "    $(docker exec "$SRV" pgbackrest version)"
echo

docker exec "$SRV" sh -c "cat > /etc/pgbackrest/pgbackrest.conf <<'CONF'
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
start-fast=y
log-level-console=detail
log-level-file=detail
log-path=/var/log/pgbackrest

[$STANZA]
pg1-path=/var/lib/postgresql/data
pg1-port=5432
pg1-host-user=postgres
CONF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf"

br() { docker exec -u postgres "$SRV" pgbackrest --stanza="$STANZA" "$@"; }

# Seed data BEFORE the backup so the restore has something to prove.
docker exec "$SRV" psql -U postgres -h localhost -q -c \
    "CREATE TABLE b4(id int primary key, payload text);
     INSERT INTO b4 SELECT g, 'row-'||g FROM generate_series(1,1000) g;" >/dev/null

step "stanza-create"     br stanza-create
step "stanza-check"      br check
step "backup-full"       br --type=full backup
step "info"              br info
step "backup-verify"     br verify || true

echo
echo "==> restoring into a fresh cluster, verified from a separate container"
# Restore straight into the path the verify container will boot, so the
# recovery.signal and restore_command pgbackrest writes point somewhere that
# exists there. Restoring to a scratch path and copying afterwards leaves a
# restore_command aimed at a directory the verify container does not have --
# the cluster then cannot fetch WAL and dies on "could not locate required
# checkpoint record", which reads like a pgrust recovery defect and is not one.
RESTORED=/var/lib/pgbackrest/_restored
docker exec -u postgres "$SRV" sh -c "rm -rf $RESTORED && mkdir -p $RESTORED"

# The restore_command runs inside the verify container, which has no
# /etc/pgbackrest/pgbackrest.conf of its own. Put a copy on the shared repo
# volume and point the server at it with PGBACKREST_CONFIG.
docker exec -u postgres "$SRV" sh -c "sed 's|^pg1-path=.*|pg1-path=$RESTORED|' \
    /etc/pgbackrest/pgbackrest.conf > /var/lib/pgbackrest/pgbackrest.conf"

if step "restore" br --pg1-path="$RESTORED" --type=default restore; then
    has_signal=no
    docker exec "$SRV" test -f "$RESTORED/recovery.signal" && has_signal=yes
    echo "    recovery.signal written by pgbackrest: $has_signal"

    docker run -d --name "$VERIFY" \
        -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
        -e PGDATA="$RESTORED" \
        -e PGBACKREST_CONFIG=/var/lib/pgbackrest/pgbackrest.conf \
        -v "$REPOVOL:/var/lib/pgbackrest" \
        "$IMAGE" >/dev/null 2>&1 || true
    up=0
    for _ in $(seq 1 90); do
        docker exec "$VERIFY" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { up=1; break; }
        sleep 1
    done
    if [ "$up" -eq 1 ]; then
        got="$(docker exec "$VERIFY" psql -U postgres -h localhost -Atc 'SELECT count(*) FROM b4' 2>&1 | tail -1)"
        if [ "$got" = "1000" ]; then
            printf '  PASS  %-30s restored cluster booted, 1000 rows intact\n' "restore-boot-verify"; pass=$((pass+1))
        else
            printf '  FAIL  %-30s booted but count(*)=[%s], expected 1000\n' "restore-boot-verify" "$got"
            FAILED+=("restore-boot-verify"); fail=$((fail+1))
        fi
    else
        printf '  FAIL  %-30s restored data directory did not boot\n' "restore-boot-verify"
        FAILED+=("restore-boot-verify"); fail=$((fail+1))
        docker logs "$VERIFY" 2>&1 | tail -14 | sed 's/^/        /'
    fi
fi

echo
echo "==> pgbackrest compat: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"
[ "$fail" -eq 0 ] || echo "==> server log tail:" && docker logs "$SRV" 2>&1 | tail -8 | sed 's/^/    /'
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
