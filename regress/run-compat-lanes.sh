#!/usr/bin/env bash
# Gate B: every ecosystem-compatibility lane, in one pass.
#
# Each lane drives the REAL C tool against pgrust -- never a reimplementation --
# and answers one question a published distribution has to answer before anyone
# puts data in it. Together they cover the lifecycle: create, back up two ways,
# restore, survive an unclean crash, get the data out portably, put a pooler in
# front, and refuse clearly what is not supported.
#
# Runs every lane even when one fails, then gates on the total. A lane that
# aborts the run hides the state of the six behind it, and this suite exists
# precisely to stop that shape of blindness.
#
# Usage:
#   regress/run-compat-lanes.sh              # all lanes
#   regress/run-compat-lanes.sh B1 B5        # only the named ones
#   PGRUST_IMAGE=pgrust:regress regress/run-compat-lanes.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export PGRUST_IMAGE="${PGRUST_IMAGE:-pgrust:pinned}"

# lane id | description | command
LANES=(
  "B1|initdb + C<->pgrust on-disk interop|regress/run-interop-compat-docker.sh"
  "B2|pg_dump / pg_restore round trip|regress/run-pgdump-compat-docker.sh"
  "B3|pg_basebackup + pg_verifybackup|regress/run-basebackup-compat-docker.sh"
  "B4|pgBackRest backup and restore|regress/run-pgbackrest-compat-docker.sh"
  "B5|kill -9 crash and restart|regress/run-crash-restart-docker.sh"
  "B68|upgrade + extension refusal|regress/run-refusal-compat-docker.sh --allow-file regress/refusal-known-failures.allow"
  "B7|real C pgBouncer in front|regress/run-pgbouncer-compat-docker.sh"
  # Recovery TAP runs in preflight-only mode until its ledger is seeded from a
  # full 47-test run. The preflight is worth gating on by itself: it proves the
  # harness still starts pgrust rather than the C binary sitting next to it,
  # which is the failure mode that would make every later recovery result a
  # green run of the wrong server.
  "A1|recovery TAP harness preflight|regress/run-recovery-tap-docker.sh --preflight-only"
)

WANT=("$@")
selected() {
    [ ${#WANT[@]} -eq 0 ] && return 0
    for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

declare -a RESULTS=()
fails=0; ran=0
for spec in "${LANES[@]}"; do
    id="${spec%%|*}"; rest="${spec#*|}"; desc="${rest%%|*}"; cmd="${rest#*|}"
    selected "$id" || continue
    ran=$((ran+1))
    echo "==================================================================="
    echo "== $id  $desc"
    echo "==================================================================="
    start=$SECONDS
    # shellcheck disable=SC2086
    if $cmd; then
        RESULTS+=("PASS|$id|$desc|$((SECONDS-start))s")
    else
        RESULTS+=("FAIL|$id|$desc|$((SECONDS-start))s")
        fails=$((fails+1))
    fi
    echo
done

echo "==================================================================="
echo "== Gate B summary"
echo "==================================================================="
for r in "${RESULTS[@]}"; do
    IFS='|' read -r st id desc dur <<<"$r"
    printf '  %-4s %-4s %-38s %s\n' "$st" "$id" "$desc" "$dur"
done
echo
echo "  $ran lanes run, $fails failed"
[ "$fails" -eq 0 ] || echo "  A failing lane means an ecosystem tool no longer works against pgrust."
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
