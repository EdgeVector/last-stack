#!/usr/bin/env bash
# WAIT_SOAK: the resoak clock. Poll the stamp until it leaves "soaking" or a
# bounded budget passes, then hand back to COLLECT. A fix earns no credit —
# host-track's own soak-watch decides green, this state only waits for it.
set -euo pipefail

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
[ -n "$app" ] || { echo "wait: app missing" >&2; exit 1; }

stamp="${HOST_TRACK_STAMP_DIR:-$HOME/.host-track/stamps}/$app.soak.json"
budget="${LOOM_SOAK_WAIT_BUDGET_S:-4800}"
step="${LOOM_SOAK_WAIT_STEP_S:-60}"
waited=0

while [ "$waited" -lt "$budget" ]; do
  if [ ! -f "$stamp" ]; then
    echo "soak-wait app=$app stamp gone (activated) after ${waited}s"
    exit 0
  fi
  status="$(jq -r '.status // ""' "$stamp")"
  if [ "$status" != "soaking" ]; then
    echo "soak-wait app=$app status=$status after ${waited}s"
    exit 0
  fi
  sleep "$step"
  waited=$((waited + step))
done
echo "soak-wait app=$app budget spent (${budget}s); still soaking"
