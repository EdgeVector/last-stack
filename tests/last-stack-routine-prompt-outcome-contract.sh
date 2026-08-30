#!/usr/bin/env bash
# Ratchet: a routine prompt must tell the harness how to report its outcome.
#
# routinesd reads the outcome from one of two places the prompt has to name:
# the authoritative sink at $ROUTINES_RUN_DIR/outcome.txt, or the legacy
# ROUTINE_RESULT trailer. A prompt that names neither still exits 0, still
# writes an `ok` heartbeat line (the heartbeat carries the exit code), and
# still reports `outcome=unknown outcomeSource=none` to the fleet.
#
# Measured 2026-08-30: coderings-weekly-fold read `unknown` on 5 of its last 6
# runs for exactly this reason, including a 19m28s run that finished exit 0.
# Its 2026-07-20 run is louder still — with no trailer to find, the parser
# captured the agent's prose as the outcome detail.
#
# The 13 names below are the prompts that carried no contract when this gate
# landed. The list may only SHRINK. Adding a name is not a fix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROMPTS="$ROOT/routines"

known_missing="
board-closeout.md
coderings-capstone-exerciser.md
devops-continuous-improvement.md
factory-health.md
fleet-performance.md
last-stack-machine-leak-scan.md
lastdb-access-watch.md
owner-review-rotate.md
product-feature-ns-reconcile.md
program-rollup.md
search-inbox-drain.md
self-upgrade.md
sentry-triage.md
"

is_known_missing() {
  local name="$1" entry
  for entry in $known_missing; do
    [ "$entry" = "$name" ] && return 0
  done
  return 1
}

declares_contract() {
  grep -q 'ROUTINE_RESULT' "$1" || grep -q 'outcome\.txt' "$1"
}

rc=0
missing_now=""

for f in "$PROMPTS"/*.md; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if declares_contract "$f"; then
    if is_known_missing "$name"; then
      echo "fail: $name now declares an outcome contract — remove it from known_missing" >&2
      rc=1
    fi
    continue
  fi
  missing_now="$missing_now $name"
  if ! is_known_missing "$name"; then
    echo "fail: $name names neither \$ROUTINES_RUN_DIR/outcome.txt nor the ROUTINE_RESULT trailer" >&2
    echo "      every run of it will report outcome=unknown outcomeSource=none" >&2
    rc=1
  fi
done

# The prompt this gate was filed for must stay fixed.
if ! declares_contract "$PROMPTS/coderings-weekly-fold.md"; then
  echo "fail: coderings-weekly-fold.md lost its outcome contract" >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  count="$(printf '%s\n' $missing_now | grep -c . || true)"
  echo "ok: routine prompt outcome contract — $count known prompt(s) still missing it"
fi

exit "$rc"
