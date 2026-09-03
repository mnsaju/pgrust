#!/usr/bin/env bash
# The "shadow-inputdir builder" that regress/isolation-overlay/schedule.extra
# already documents itself as needing (see that file's header comment) --
# this was the missing piece behind PGRA-017 (review/opus/findings.md):
# regress/overlay/ and regress/isolation-overlay/ are DELTAS against the
# vendored PostgreSQL suite (vendor/postgresql/src/test/{regress,isolation}),
# not complete trees, and nothing in the repo combined them until now.
#
# Builds two "shadow" input directories under $OUT (default: regress-work/),
# each a full copy of the vendor tree with pgrust's overlay applied on top:
#
#   regress-work/regress/    -- vendor src/test/regress + regress/overlay/sql
#                                (same-named files replaced)
#   regress-work/isolation/  -- vendor src/test/isolation +
#                                regress/isolation-overlay/{specs,expected}
#                                (new files, additive) + schedule.extra's
#                                lines appended to isolation_schedule
#
# Usage: scripts/lane-epq-inc1-e2e.sh [OUT_DIR]
# Idempotent: safe to re-run: rebuilds both shadow dirs from scratch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_REGRESS="$REPO_ROOT/vendor/postgresql/src/test/regress"
VENDOR_ISOLATION="$REPO_ROOT/vendor/postgresql/src/test/isolation"
OVERLAY_REGRESS_SQL="$REPO_ROOT/regress/overlay/sql"
OVERLAY_ISOLATION="$REPO_ROOT/regress/isolation-overlay"
OUT="${1:-$REPO_ROOT/regress-work}"

for d in "$VENDOR_REGRESS" "$VENDOR_ISOLATION"; do
    if [ ! -d "$d" ]; then
        echo "FAIL: $d not found -- run vendor/setup.sh first" >&2
        exit 1
    fi
done

echo "==> Building shadow regress inputdir at $OUT/regress"
rm -rf "$OUT/regress"
mkdir -p "$OUT/regress"
cp -a "$VENDOR_REGRESS/." "$OUT/regress/"
cp -a "$OVERLAY_REGRESS_SQL/." "$OUT/regress/sql/"
echo "    $(find "$OVERLAY_REGRESS_SQL" -name '*.sql' | wc -l) overlay files applied over $(find "$VENDOR_REGRESS/sql" -name '*.sql' | wc -l) vendor sql files"

echo "==> Building shadow isolation inputdir at $OUT/isolation"
rm -rf "$OUT/isolation"
mkdir -p "$OUT/isolation"
cp -a "$VENDOR_ISOLATION/." "$OUT/isolation/"
cp -a "$OVERLAY_ISOLATION/specs/." "$OUT/isolation/specs/"
cp -a "$OVERLAY_ISOLATION/expected/." "$OUT/isolation/expected/"

SCHEDULE="$OUT/isolation/isolation_schedule"
{
    echo ""
    echo "# --- appended by scripts/lane-epq-inc1-e2e.sh from regress/isolation-overlay/schedule.extra ---"
    grep -v '^\s*#' "$OVERLAY_ISOLATION/schedule.extra" | grep -v '^\s*$'
} >> "$SCHEDULE"
ADDED=$(grep -c '^test:' "$OVERLAY_ISOLATION/schedule.extra")
echo "    appended $ADDED overlay spec(s) to isolation_schedule (now $(grep -c '^test:' "$SCHEDULE") total)"

echo "==> Done. regress: $OUT/regress  isolation: $OUT/isolation"
