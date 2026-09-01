#!/usr/bin/env bash
# Run the Rust PgBouncer compatibility tests and, optionally, the full
# upstream PgBouncer pytest suite with pgrust as the PostgreSQL Docker backend.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../../.." && pwd)
package=pgbouncer_compat
image=${PGRUST_IMAGE:-pgrust:pgbouncer}
upstream_dir=${PGBOUNCER_UPSTREAM_DIR:-"$repo_root/target/pgbouncer-upstream"}
run_upstream=false
build_image=true
selectors=()

usage() {
    cat <<'EOF'
Usage: run-all.sh [options] [pytest selectors...]

Runs the native Rust test suite for the PgBouncer implementation. Pass
--upstream to additionally run the selected upstream PgBouncer pytest cases
against a pgrust Docker backend. With no selectors, --upstream runs the full
upstream test/ directory.

Options:
  --upstream                 Run upstream PgBouncer pytest cases too.
  --upstream-dir PATH        Existing PgBouncer checkout, or a checkout path
                             created under target/ when it does not exist.
  --image TAG                pgrust Docker image tag (default: pgrust:pgbouncer).
  --skip-image-build         Reuse the selected pgrust image.
  -h, --help                 Show this help.

Prerequisites for --upstream: docker, git, uv, and a PostgreSQL client
(psql) on PATH. The script builds pgrust-pgbouncer in release mode and uses
the upstream Python suite without copying its C or Python implementation.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: %s is required\n' "$1" >&2
        exit 2
    }
}

while (($#)); do
    case "$1" in
        --upstream)
            run_upstream=true
            ;;
        --upstream-dir)
            (($# >= 2)) || { printf 'error: --upstream-dir requires a path\n' >&2; exit 2; }
            upstream_dir=$2
            shift
            ;;
        --image)
            (($# >= 2)) || { printf 'error: --image requires a tag\n' >&2; exit 2; }
            image=$2
            shift
            ;;
        --skip-image-build)
            build_image=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            selectors+=("$1")
            ;;
    esac
    shift
done

require_command cargo
printf '%s\n' '==> Running native Rust tests'
(cd "$repo_root" && cargo test -p "$package" --all-targets)

if ! "$run_upstream"; then
    exit 0
fi

for command in docker git uv psql; do
    require_command "$command"
done

printf '%s\n' '==> Building the Rust PgBouncer binary'
(cd "$repo_root" && cargo build --release -p "$package" --bin pgrust-pgbouncer)

if "$build_image"; then
    printf '%s\n' "==> Building pgrust backend image $image"
    docker build --tag "$image" "$repo_root"
fi

if [[ ! -d "$upstream_dir/.git" ]]; then
    printf '%s\n' "==> Cloning PgBouncer upstream tests into $upstream_dir"
    mkdir -p "$(dirname -- "$upstream_dir")"
    git clone --depth 1 https://github.com/pgbouncer/pgbouncer "$upstream_dir"
fi

if ((${#selectors[@]} == 0)); then
    selectors=(test)
fi

printf '%s\n' '==> Running upstream PgBouncer tests against pgrust Docker'
(
    cd "$upstream_dir"
    uv sync
    BOUNCER_EXE="$repo_root/target/release/pgrust-pgbouncer" \
    PGRUST_IMAGE="$image" \
    PYTHONPATH="$repo_root/crates/integration/pgbouncer/tests/upstream${PYTHONPATH:+:$PYTHONPATH}" \
        uv run pytest -p pgrust_docker "${selectors[@]}"
)
