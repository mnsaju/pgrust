#!/usr/bin/env bash
# Runs upstream PostgreSQL's per-contrib-module regression tests (vendored at
# vendor/postgresql/contrib/*/{sql,expected}) against a real pgrust server in
# Docker.
#
# Companion to run-regress-docker.sh, and deliberately the same shape: real
# PGDG `pg_regress --use-existing` ("existing installation" mode, what
# `make installcheck` uses) driven against the pgrust container's own
# postmaster. No TAP, no binary substitution -- this reuses the machinery the
# core-suite runner already proved, which is why it is the cheapest way to
# cover the extensions tier.
#
# Scope: pgrust ports upstream's contrib extensions as built-in Rust crates
# (there is no dlopen ABI), so a module is only runnable if its extension name
# appears in pg_available_extensions on the running server. Modules that do
# not (PL-dependent glue like hstore_plperl, plus sepgsql/xml2/spi/...) are
# reported SKIP, never silently passed.
#
# Each module's REGRESS list comes from its own upstream Makefile, so test
# order matches what `make installcheck` in that directory would do.
#
# Usage: regress/run-contrib-regress-docker.sh [--allow-file PATH] [module ...]
#   --allow-file turns the run into a CI gate with the same ratchet semantics
#   as the core suite's: a listed module may fail, an unlisted failure breaks
#   the build, and a listed module that starts passing is stale and also
#   breaks the build -- so the ledger can only shrink.
#   With no arguments, runs every runnable module. Named modules restrict the
#   run, e.g.:  regress/run-contrib-regress-docker.sh hstore citext cube
#
# Requires: docker. Set PGRUST_IMAGE to reuse an already-built image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PGRUST_IMAGE:-pgrust:regress}"
# Unique per invocation: a fixed name means a second run (say, reproducing one
# module while a full sweep is in flight) `docker rm -f`s the first run's
# container out from under it -- the sweep then dies with status 137 on
# whatever test was mid-flight, which looks exactly like a pgrust crash.
CONTAINER="pgrust-contrib-regress-$$"
CONTRIB_SRC="$REPO_ROOT/vendor/postgresql/contrib"
WORK="$REPO_ROOT/regress-work/contrib"

if [ ! -d "$CONTRIB_SRC" ]; then
    echo "FAIL: $CONTRIB_SRC missing -- run: git submodule update --init vendor/postgresql" >&2
    exit 2
fi

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building the pgrust image (none cached for $IMAGE)"
    docker build -t "$IMAGE" "$REPO_ROOT"
else
    echo "==> Reusing image $IMAGE"
fi

rm -rf "$WORK"; mkdir -p "$WORK"

echo "==> Starting pgrust (C-locale initdb, matching expected/*.out assumptions)"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=secret -e POSTGRES_INITDB_ARGS="--locale=C --encoding=UTF8" \
    -v "$CONTRIB_SRC":/contrib-src:ro \
    "$IMAGE" >/dev/null

wait_ready() {
    for _ in $(seq 1 90); do
        docker exec "$CONTAINER" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

ready=0
for _ in $(seq 1 90); do
    if docker exec "$CONTAINER" psql -U postgres -h localhost -c 'SELECT 1' >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: server never became ready"; docker logs "$CONTAINER" || true; exit 1
fi

# Extension availability decides runnability: a crate directory name is not the
# extension name (crates/contrib/uuid_ossp provides "uuid-ossp"), so ask the
# server rather than guessing from paths.
AVAIL="$(docker exec "$CONTAINER" psql -U postgres -h localhost -tAc \
    'SELECT name FROM pg_available_extensions ORDER BY 1')"

ALLOW_FILE=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-file) ALLOW_FILE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
    mapfile -t MODULES < <(ls -d "$CONTRIB_SRC"/*/sql 2>/dev/null | sed 's|.*/contrib/||;s|/sql$||' | sort)
fi

REGRESS_BIN=/usr/lib/postgresql/18/lib/pgxs/src/test/regress/pg_regress
psqlpg() { docker exec "$CONTAINER" psql -U postgres -h localhost -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }

pass=0; fail=0; skip=0
declare -a FAILED=() SKIPPED=()

for mod in "${MODULES[@]}"; do
    mk="$CONTRIB_SRC/$mod/Makefile"
    [ -f "$mk" ] || { SKIPPED+=("$mod (no Makefile)"); skip=$((skip+1)); continue; }

    # REGRESS is continued across backslashes in five modules (btree_gin,
    # btree_gist, pgcrypto, pg_stat_statements, test_decoding). A plain
    # `sed -n 's/^REGRESS *= *//p'` matches only lines that START with REGRESS,
    # so every continuation line is dropped -- 84 tests silently unrun across
    # those five, each still reporting PASS on the subset. Join explicitly.
    tests="$(awk '
        /^REGRESS[[:space:]]*=/ { sub(/^REGRESS[[:space:]]*=[[:space:]]*/, ""); inlist = 1 }
        inlist {
            cont = /\\$/
            sub(/[[:space:]]*\\$/, "")
            printf "%s ", $0
            if (!cont) exit
        }
    ' "$mk")"

    # A REGRESS entry can be a make variable (pgcrypto's $(CF_PGP_TESTS), which
    # expands through $(if $(subst ...)) to pgp-compression or a DISABLED
    # placeholder depending on --with-zlib). Evaluating make is not this
    # runner's job, but passing the token through unexpanded makes pg_regress
    # try to open "sql/$(CF_PGP_TESTS).sql" and bail out the whole module. Drop
    # such tokens -- and SAY SO, because a silently shortened list is precisely
    # the defect this parser was fixed for.
    unexpanded="$(tr ' ' '\n' <<<"$tests" | grep -F '$(' || true)"
    if [ -n "$unexpanded" ]; then
        tests="$(tr ' ' '\n' <<<"$tests" | grep -vF '$(' | tr '\n' ' ')"
        printf '  NOTE  %-22s skipping unexpanded make variable(s): %s\n' \
            "$mod" "$(tr '\n' ' ' <<<"$unexpanded")"
    fi
    [ -n "${tests// }" ] || { SKIPPED+=("$mod (no REGRESS tests)"); skip=$((skip+1)); continue; }

    # The extension the module provides: its .control file's stem. Some modules
    # ship no .control at all (auto_explain and friends are preload-only, not
    # CREATE EXTENSION targets) -- those get no availability gate, we just try
    # them. Written with compgen rather than `ls *.control` because a failing
    # glob under `set -e -o pipefail` aborts the whole run, which is exactly
    # how the first full run died after one module.
    ext=""
    if compgen -G "$CONTRIB_SRC/$mod/*.control" >/dev/null 2>&1; then
        ext="$(basename "$(compgen -G "$CONTRIB_SRC/$mod/*.control" | head -1)" .control)"
    fi
    if [ -n "$ext" ] && ! grep -qx "$ext" <<<"$AVAIL"; then
        SKIPPED+=("$mod (extension \"$ext\" not available in pgrust)"); skip=$((skip+1)); continue
    fi

    db="contrib_${mod//-/_}"
    psqlpg "DROP DATABASE IF EXISTS \"$db\";"
    psqlpg "CREATE DATABASE \"$db\" TEMPLATE=template0 ENCODING='UTF8' LOCALE='C';"
    psqlpg "
        ALTER DATABASE \"$db\" SET lc_messages TO 'C';
        ALTER DATABASE \"$db\" SET lc_monetary TO 'C';
        ALTER DATABASE \"$db\" SET lc_numeric TO 'C';
        ALTER DATABASE \"$db\" SET lc_time TO 'C';
        ALTER DATABASE \"$db\" SET bytea_output TO 'hex';
        ALTER DATABASE \"$db\" SET timezone_abbreviations TO 'Default';
    "

    # REGRESS_OPTS = --temp-config <file> names a plain key=value config the
    # module needs (shared_preload_libraries, wal_level, ...). pg_regress only
    # honours it in temp-instance mode, which --use-existing is not, so apply
    # it to the live server instead. These are POSTMASTER-context settings, so
    # the server must be bounced -- and bounced back afterwards, or the setting
    # leaks into every later module.
    tmpconf="$(sed -n 's/.*--temp-config[[:space:]]*[^ ]*\/contrib\/\([^ ]*\).*/\1/p' "$mk" | head -1)"
    reconfigured=0
    if [ -n "$tmpconf" ] && [ -f "$CONTRIB_SRC/${tmpconf#*/}" ]; then
        conf="$CONTRIB_SRC/${tmpconf#*/}"
    elif [ -n "$tmpconf" ] && [ -f "$CONTRIB_SRC/$tmpconf" ]; then
        conf="$CONTRIB_SRC/$tmpconf"
    else
        conf=""
    fi
    if [ -n "$conf" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"; line="$(echo "$line" | sed 's/[[:space:]]*$//')"
            [ -z "$line" ] && continue
            key="$(echo "$line" | cut -d= -f1 | sed 's/[[:space:]]*$//')"
            val="$(echo "$line" | cut -d= -f2- | sed "s/^[[:space:]]*//")"
            # The conf file already quotes string values ("shared_preload_libraries
            # = 'pg_stat_statements'"). Strip that pair before re-quoting, or the
            # setting becomes the literal string "'pg_stat_statements'" -- which
            # is an invalid library name and the server then fails to start.
            case "$val" in "'"*"'") val="${val#\'}"; val="${val%\'}" ;; esac
            val="$(printf '%s' "$val" | sed "s/'/''/g")"
            psqlpg "ALTER SYSTEM SET $key = '$val';" || true
        done < "$conf"
        docker restart "$CONTAINER" >/dev/null
        wait_ready || { echo "  FAIL  $mod (server did not return after config restart)"; FAILED+=("$mod"); fail=$((fail+1)); continue; }
        reconfigured=1
    fi

    docker exec "$CONTAINER" rm -rf "/tmp/out-$mod"
    docker exec "$CONTAINER" mkdir -p "/tmp/out-$mod"
    status=0
    # shellcheck disable=SC2086 -- $tests is an intentional word list
    # -w: several modules' .sql use paths relative to the module directory
    # (hstore's `\copy testhstore from 'data/hstore.data'`), which pg_regress
    # resolves against the CWD, not --inputdir. `make installcheck` runs from
    # inside the module dir, so match that or those tests fail spuriously.
    docker exec -w "/contrib-src/$mod" "$CONTAINER" "$REGRESS_BIN" \
        --use-existing --host=localhost --port=5432 --user=postgres \
        --dbname="$db" \
        --inputdir="/contrib-src/$mod" --outputdir="/tmp/out-$mod" \
        $tests >"$WORK/$mod.log" 2>&1 || status=$?

    docker cp "$CONTAINER:/tmp/out-$mod" "$WORK/$mod-output" >/dev/null 2>&1 || true

    if [ "$reconfigured" -eq 1 ]; then
        psqlpg "ALTER SYSTEM RESET ALL;" || true
        docker restart "$CONTAINER" >/dev/null
        wait_ready || { echo "FAIL: server did not return after config reset"; exit 1; }
    fi

    # A module whose extension pgrust does not implement fails with C's
    # file-not-found from dfmgr's builtin registry ("no dlopen exists"). That
    # is "not ported", not a defect -- classify it with the skips so a ledger
    # never enshrines it as a known failure.
    if [ "$status" -ne 0 ] && grep -qE 'could not access file "' "$WORK/$mod-output/regression.diffs" 2>/dev/null; then
        missing="$(grep -m1 -oE 'could not access file "[^"]*"' "$WORK/$mod-output/regression.diffs")"
        printf '  SKIP  %-22s not ported (%s)\n' "$mod" "$missing"
        SKIPPED+=("$mod (not ported: $missing)"); skip=$((skip+1)); continue
    fi

    if [ "$status" -eq 0 ]; then
        printf '  PASS  %-22s (%s)\n' "$mod" "$(echo $tests | wc -w) tests"
        pass=$((pass+1))
    else
        printf '  FAIL  %-22s status=%s  -> %s\n' "$mod" "$status" "$WORK/$mod.log"
        FAILED+=("$mod"); fail=$((fail+1))
    fi
done

echo
echo "==> contrib summary: $pass passed, $fail failed, $skip skipped"
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo "    skipped:"; printf '      - %s\n' "${SKIPPED[@]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "    failed:"; printf '      - %s\n' "${FAILED[@]}"
fi
echo "==> logs + diffs under $WORK"

# Without a ledger this is a report, not a gate: "some tests failed" is an
# outcome to read, not a harness error, exactly as the core runner treats it.
if [ -z "$ALLOW_FILE" ]; then
    exit 0
fi

if [ ! -f "$ALLOW_FILE" ]; then
    echo "FAIL: --allow-file $ALLOW_FILE not found" >&2
    exit 2
fi
mapfile -t ALLOWED < <(sed 's/#.*//' "$ALLOW_FILE" | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u)
mapfile -t ACTUAL < <(printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | grep -v '^$' | sort -u)

new_failures="$(comm -13 <(printf '%s\n' "${ALLOWED[@]+"${ALLOWED[@]}"}") <(printf '%s\n' "${ACTUAL[@]+"${ACTUAL[@]}"}"))"
stale="$(comm -23 <(printf '%s\n' "${ALLOWED[@]+"${ALLOWED[@]}"}") <(printf '%s\n' "${ACTUAL[@]+"${ACTUAL[@]}"}"))"

echo
echo "==> ratchet ledger: $ALLOW_FILE (${#ALLOWED[@]} entries)"
rc=0
if [ -n "$new_failures" ]; then
    echo "    NEW failures (not in ledger):"; echo "$new_failures" | sed 's/^/      - /'
    rc=1
fi
if [ -n "$stale" ]; then
    echo "    STALE entries (now passing -- remove them):"; echo "$stale" | sed 's/^/      - /'
    rc=1
fi
[ "$rc" -eq 0 ] && echo "    no new failures, no stale entries"
exit "$rc"
