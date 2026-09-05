#!/usr/bin/env bash
# Lanes B6 (upgrade refusal) and B8 (extension refusal).
#
# Both lanes test the same property from two directions: when pgrust cannot do
# something, does it say so LOUDLY? This is negative-space testing, and for a
# published distribution it matters as much as the positive lanes -- a silent
# refusal is indistinguishable from success until someone's data is already
# gone. The contrib ledger already carries one instance (basic_archive fails
# silently because archive_library is unported, so the runner's not-ported
# detector cannot see it), which is what motivated this lane.
#
# Every refusal is additionally checked for NOT being a Rust panic. An unported
# path that panics is a crash, not a refusal, and in a thread-per-backend
# server a panic in the wrong place takes the cluster with it.
set -euo pipefail

IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"
PGDATA=/var/lib/postgresql/data
SRV="b68-srv-$$"; VOL="b68-vol-$$"
ALLOW=""
[ "${1:-}" = "--allow-file" ] && { ALLOW="$2"; shift 2; }

cleanup() { docker rm -f "$SRV" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

pass=0; fail=0; declare -a FAILED=()
ok()  { printf '  PASS  %-34s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  FAIL  %-34s %s\n' "$1" "${2:-}"; FAILED+=("$1"); fail=$((fail+1)); }
nopanic() { case "$1" in *"panicked at"*|*RUST_BACKTRACE*) return 1;; *) return 0;; esac; }

docker volume create "$VOL" >/dev/null
echo "==> initialising a cluster to tamper with"
docker run -d --name "$SRV" -v "$VOL:$PGDATA" \
    -e POSTGRES_PASSWORD=x -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_INITDB_ARGS="--no-locale --encoding=UTF8" "$IMAGE" >/dev/null
up=0
for _ in $(seq 1 90); do docker exec "$SRV" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[ "$up" -eq 1 ] || { echo "FAIL: pgrust never became ready"; docker logs "$SRV" 2>&1 | tail -12; exit 2; }

# ===========================================================================
# B8 -- extension and library refusal (server up)
# ===========================================================================
echo
echo "== B8: extension / library refusal =="
# Every query here is EXPECTED to fail; psql exits 1 on a SQL error and
# `set -o pipefail` would otherwise abort the whole lane at the first refusal
# it was written to observe.
q() {
    local o
    o="$(docker exec "$SRV" psql -U postgres -h localhost -Atc "$1" 2>&1 || true)"
    printf '%s' "$o" | tr '\n' ' '
}

out="$(q 'CREATE EXTENSION hstore')"
case "$out" in *ERROR*) bad "positive-control-ported-ext" "hstore should install: $out" ;;
                     *) ok "positive-control-ported-ext" "hstore installs" ;; esac

for ext in dict_int xml2 passwordcheck; do
    out="$(q "CREATE EXTENSION $ext")"
    if ! nopanic "$out"; then bad "unported-ext-$ext" "PANICKED: $(echo "$out" | cut -c1-90)"
    elif case "$out" in *ERROR*) true;; *) false;; esac; then
        ok "unported-ext-$ext" "$(echo "$out" | sed 's/.*ERROR: *//' | cut -c1-56)"
    else
        bad "unported-ext-$ext" "did not error: $(echo "$out" | cut -c1-80)"
    fi
done

out="$(q "CREATE EXTENSION no_such_extension_xyz")"
case "$out" in *ERROR*) ok "nonexistent-ext-errors" ;; *) bad "nonexistent-ext-errors" "$out" ;; esac

out="$(q "LOAD 'no_such_library_xyz'")"
if ! nopanic "$out"; then bad "load-nonexistent-library" "PANICKED"
else case "$out" in *ERROR*) ok "load-nonexistent-library" ;; *) bad "load-nonexistent-library" "did not error: $out" ;; esac; fi

# The server must still be alive after every refusal above.
alive="$(q 'SELECT 1' | tr -d ' ')"
if [ "$alive" = "1" ]; then ok "server-survives-refusals"
else bad "server-survives-refusals" "got [$alive]"; fi

# Known silent failure, kept as an executable record rather than a comment:
# archive_library names an unported library and the server accepts it without
# complaint, so archiving simply never happens. This is the mechanism behind
# the contrib ledger's basic_archive entry.
out="$(q "ALTER SYSTEM SET archive_library = 'no_such_archive_lib'")"
if case "$out" in *ERROR*) true;; *) false;; esac; then
    ok "archive_library-refused" "rejected at ALTER SYSTEM"
else
    bad "archive_library-refused" "accepted silently -- the basic_archive mechanism"
fi
docker exec "$SRV" psql -U postgres -h localhost -q -c "ALTER SYSTEM RESET archive_library" >/dev/null 2>&1 || true

# ===========================================================================
# B6 -- upgrade / wrong-version refusal (server down, data directory tampered)
# ===========================================================================
echo
echo "== B6: version refusal (no in-place upgrade is supported) =="
docker exec -u postgres "$SRV" /usr/lib/postgresql/18/bin/pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || docker stop -t 30 "$SRV" >/dev/null
docker rm -f "$SRV" >/dev/null 2>&1 || true

try_boot() { # writes PG_VERSION=$1, returns combined output of a foreground start
    docker run --rm -v "$VOL:$PGDATA" --entrypoint sh "$IMAGE" \
        -c "echo '$1' > $PGDATA/PG_VERSION" >/dev/null 2>&1
    timeout 60 docker run --rm -v "$VOL:$PGDATA" --user postgres \
        --entrypoint /usr/local/bin/pgrust-postgres "$IMAGE" -D "$PGDATA" \
        -c listen_addresses='' -c unix_socket_directories=/tmp 2>&1 | head -30
}

for ver in 17 19; do
    out="$(try_boot "$ver" || true)"
    label=$([ "$ver" = 17 ] && echo "older" || echo "newer")
    if ! nopanic "$out"; then
        bad "refuse-PG_VERSION-$ver" "PANICKED instead of refusing ($label major)"
    elif case "$out" in *FATAL*|*"is not compatible"*|*"was initialized"*) true;; *) false;; esac; then
        ok "refuse-PG_VERSION-$ver" "$(echo "$out" | grep -iE 'FATAL|not compatible' | head -1 | sed 's/.*FATAL: *//' | cut -c1-58)"
    else
        bad "refuse-PG_VERSION-$ver" "started or failed unclearly: $(echo "$out" | tr '\n' ' ' | cut -c1-90)"
    fi
done
docker run --rm -v "$VOL:$PGDATA" --entrypoint sh "$IMAGE" -c "echo 18 > $PGDATA/PG_VERSION" >/dev/null 2>&1

# A truncated control file must be a clean FATAL, never a panic or a segfault.
docker run --rm -v "$VOL:$PGDATA" --entrypoint sh "$IMAGE" \
    -c "cp $PGDATA/global/pg_control /tmp/c.bak && head -c 32 /tmp/c.bak > $PGDATA/global/pg_control" >/dev/null 2>&1
out="$(timeout 60 docker run --rm -v "$VOL:$PGDATA" --user postgres \
    --entrypoint /usr/local/bin/pgrust-postgres "$IMAGE" -D "$PGDATA" \
    -c listen_addresses='' -c unix_socket_directories=/tmp 2>&1 | head -30 || true)"
if ! nopanic "$out"; then
    bad "refuse-truncated-pg_control" "PANICKED on a corrupt control file"
elif case "$out" in *FATAL*|*PANIC*|*"control file"*|*"incorrect checksum"*) true;; *) false;; esac; then
    ok "refuse-truncated-pg_control" "$(echo "$out" | grep -iE 'FATAL|PANIC|control file' | head -1 | cut -c1-58)"
else
    bad "refuse-truncated-pg_control" "unclear: $(echo "$out" | tr '\n' ' ' | cut -c1-90)"
fi

echo
echo "==> refusals: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && printf '    failed: %s\n' "${FAILED[*]}"

if [ -n "$ALLOW" ] && [ -f "$ALLOW" ]; then
    allowed="$(grep -v '^\s*#' "$ALLOW" | grep -v '^\s*$' || true)"
    rc=0
    for f in ${FAILED[@]+"${FAILED[@]}"}; do
        grep -qx "$f" <<<"$allowed" || { echo "  NEW failure not in ledger: $f"; rc=1; }
    done
    for a in $allowed; do
        printf '%s\n' ${FAILED[@]+"${FAILED[@]}"} | grep -qx "$a" \
            || { echo "  STALE ledger entry (now passing): $a"; rc=1; }
    done
    [ "$rc" -eq 0 ] && echo "  no new failures, no stale entries"
    exit "$rc"
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
