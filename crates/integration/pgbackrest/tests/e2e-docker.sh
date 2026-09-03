#!/usr/bin/env bash
# End-to-end verification of pgbackrest_compat's Phase-1 hardening
# (compression, parallel copy, delta restore, retention pruning) against a
# real pgRust server, using the repository's own Docker image rather than
# requiring PostgreSQL 18 tooling on the host.
#
# What this proves that the unit tests in src/repository.rs cannot:
#   - a real initdb-created data directory backs up and restores correctly
#     under compression + parallel copy, using the actual CLI binary
#   - the restored data directory actually starts a fresh, independent
#     pgRust postgres server and serves the seeded data back correctly, not
#     just "files match on disk"
#
# Known limitation this script deliberately routes around: `pg_ctl stop`'s
# client-side wait loop hangs indefinitely against this image even though
# the server itself shuts down in well under a second (confirmed via
# container logs) — a separate, pre-existing bug in pgRust's pg_ctl outside
# this crate's scope. Shutdown here uses `kill -INT 1` (the same signal
# "fast" shutdown sends) plus polling Docker's own container state, which
# does not depend on pg_ctl's wait logic at all.
#
# PGDATA is a Dockerfile-declared VOLUME, which `docker commit` does NOT
# capture — so moving the stopped cluster to an exec'able container uses
# `--volumes-from` (shares the live volume) rather than commit/run.
#
# Usage: crates/integration/pgbackrest/tests/e2e-docker.sh
# Requires: docker, cargo. Set PGRUST_IMAGE to reuse an already-built image
# (e.g. pgrust:audit); otherwise this builds one from the repository root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:pgbackrest-e2e}"
SOURCE_CONTAINER="pgrust-pgbackrest-e2e-source"
WORK_CONTAINER="pgrust-pgbackrest-e2e-work"
VERIFY_CONTAINER="pgrust-pgbackrest-e2e-verify"
RESTORED_VOLUME="pgrust-pgbackrest-e2e-restored"
BUILD_TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target-user}"

cleanup() {
    docker rm -f "$SOURCE_CONTAINER" "$WORK_CONTAINER" "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm -f "$RESTORED_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building pgrust-pgbackrest on the host"
CARGO_TARGET_DIR="$BUILD_TARGET_DIR" cargo build \
    --manifest-path "$REPO_ROOT/Cargo.toml" -p pgbackrest_compat --bin pgrust-pgbackrest
BACKREST_BIN="$BUILD_TARGET_DIR/debug/pgrust-pgbackrest"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building the pgrust Docker image (no cached image found for $IMAGE)"
    docker build -t "$IMAGE" "$REPO_ROOT"
else
    echo "==> Reusing existing image $IMAGE (set PGRUST_IMAGE=<other> or remove it to rebuild)"
fi

cleanup

echo "==> Starting a source container and waiting for it to accept connections"
docker run -d --name "$SOURCE_CONTAINER" -e POSTGRES_PASSWORD=e2e-secret "$IMAGE" >/dev/null
ready=0
for _ in $(seq 1 30); do
    if docker exec "$SOURCE_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: server never became ready"
    docker logs "$SOURCE_CONTAINER" || true
    exit 1
fi

echo "==> Seeding a table so restore correctness is verifiable"
docker exec -u postgres "$SOURCE_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -c \
    "create table e2e_check (id int primary key, note text);
     insert into e2e_check values (1, 'hello'), (2, 'world');"
BEFORE_MD5=$(docker exec -u postgres "$SOURCE_CONTAINER" psql -U postgres -tAc \
    "select md5(string_agg(id::text || note, ',' order by id)) from e2e_check;")

echo "==> Stopping the server (fast shutdown via signal + Docker state, not pg_ctl — see header)"
docker exec "$SOURCE_CONTAINER" sh -c 'kill -INT 1'
stopped=0
for _ in $(seq 1 30); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$SOURCE_CONTAINER" 2>/dev/null)" = "false" ]; then
        stopped=1
        break
    fi
    sleep 1
done
if [ "$stopped" -ne 1 ]; then
    echo "FAIL: server never stopped"
    docker logs "$SOURCE_CONTAINER" || true
    exit 1
fi

echo "==> Attaching an exec'able container to the stopped cluster's volume"
docker volume create "$RESTORED_VOLUME" >/dev/null
docker run -d --name "$WORK_CONTAINER" \
    --volumes-from "$SOURCE_CONTAINER" \
    -v "$RESTORED_VOLUME:/mnt/restored" \
    --entrypoint sleep "$IMAGE" infinity >/dev/null
docker exec "$WORK_CONTAINER" chown postgres:postgres /mnt/restored
docker cp "$BACKREST_BIN" "$WORK_CONTAINER:/usr/local/bin/pgrust-pgbackrest"

CONF=/tmp/e2e-pgbackrest.conf
docker exec -i "$WORK_CONTAINER" sh -c "cat > $CONF" <<EOF
[global]
repo1-path=/tmp/e2e-repo
pg1-path=/var/lib/postgresql/data
process-max=4
repo1-retention-full=2
EOF
CFG=(--config="$CONF" --stanza=e2e)

echo "==> stanza-create + three full backups (compression + parallel copy on)"
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" stanza-create
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" backup
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" backup
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" backup

echo "==> Verifying compression actually produced .pglz files"
docker exec "$WORK_CONTAINER" sh -c "find /tmp/e2e-repo/backup/e2e -name '*.pglz' | grep -q pglz"

echo "==> expire down to the configured retention"
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" expire
REMAINING=$(docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" info | wc -l)
if [ "$REMAINING" -ne 2 ]; then
    echo "FAIL: expected 2 backups to remain after expire, found $REMAINING"
    exit 1
fi

echo "==> check (integrity verification of what expire left behind)"
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" check

echo "==> restore into the scratch volume, then a second delta restore over it"
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" restore /mnt/restored
docker exec -u postgres "$WORK_CONTAINER" pgrust-pgbackrest "${CFG[@]}" restore --delta /mnt/restored

echo "==> Starting a fresh, independent container against the restored volume"
docker run -d --name "$VERIFY_CONTAINER" -v "$RESTORED_VOLUME:/var/lib/postgresql/data" \
    -e POSTGRES_PASSWORD=e2e-secret "$IMAGE" >/dev/null
ready=0
for _ in $(seq 1 30); do
    if docker exec "$VERIFY_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: restored server never became ready"
    docker logs "$VERIFY_CONTAINER" || true
    exit 1
fi

AFTER_MD5=$(docker exec -u postgres "$VERIFY_CONTAINER" psql -U postgres -tAc \
    "select md5(string_agg(id::text || note, ',' order by id)) from e2e_check;")

if [ "$BEFORE_MD5" != "$AFTER_MD5" ]; then
    echo "FAIL: restored data does not match (before=$BEFORE_MD5 after=$AFTER_MD5)"
    exit 1
fi

echo "==> PASS: backup/expire/delta-restore round-tripped a real server's data correctly (checksum $BEFORE_MD5)"
