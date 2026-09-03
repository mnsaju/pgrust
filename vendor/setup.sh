#!/usr/bin/env bash
# Reproduces vendor/postgresql: a shallow, sparse-checked-out clone of
# PostgreSQL's src/test/regress + src/test/isolation at a pinned tag.
# `git submodule update --init` alone does a full, unshallow clone instead
# -- this is what actually produced the committed gitlink. See
# vendor/README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_TAG="REL_18_3"
DEST="$REPO_ROOT/vendor/postgresql"

if [ -d "$DEST/.git" ]; then
    echo "==> $DEST already exists; remove it first to re-vendor"
    exit 0
fi

mkdir -p "$DEST"
cd "$DEST"
git init -q
git remote add origin https://github.com/postgres/postgres.git
git fetch --depth 1 origin "tag" "$REL_TAG"
git checkout -q "$REL_TAG"
git sparse-checkout init --cone
git sparse-checkout set src/test/regress src/test/isolation

echo "==> vendor/postgresql set up at $REL_TAG ($(git rev-parse HEAD))"
echo "==> run: git -C $REPO_ROOT add vendor/postgresql   # to record this commit"
