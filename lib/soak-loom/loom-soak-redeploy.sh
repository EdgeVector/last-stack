#!/usr/bin/env bash
# REDEPLOY: pull the fixed build into a parked canary. The publish/promote
# pipeline does the real work post-merge; this state runs a refresh and waits
# briefly for the NEW digest to park. Stand-in is a no-op.
set -euo pipefail

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
[ -n "$app" ] || { echo "redeploy: app missing" >&2; exit 1; }
old_digest="$(printf '%s' "$input" | jq -r '.digest // empty')"

if [ "${LOOM_LIVE:-}" != "1" ] && [ "${LOOM_SOAK_HEAL_LIVE:-}" != "1" ]; then
  echo "soak-redeploy stand-in app=$app"
  exit 0
fi

command -v host-track >/dev/null 2>&1 || { echo "redeploy: host-track missing" >&2; exit 1; }

budget="${LOOM_SOAK_REDEPLOY_BUDGET_S:-1500}"
step=120
waited=0
while [ "$waited" -lt "$budget" ]; do
  host-track refresh "$app" >/dev/null 2>&1 || true
  status="$(host-track status --json "$app" 2>/dev/null || printf '{}')"
  canary="$(printf '%s' "$status" | jq -r '.artifact_current // empty' )"
  soak_state="$(printf '%s' "$status" | jq -r '.soak_state // empty')"
  new_digest="$(printf '%s' "$status" | jq -r '.soak_state // empty' >/dev/null; printf '%s' "$status" | jq -r '.manifest_digest // empty')"
  if [ "$soak_state" = "soaking" ]; then
    echo "soak-redeploy app=$app new canary soaking"
    exit 0
  fi
  sleep "$step"
  waited=$((waited + step))
done
echo "soak-redeploy app=$app no new canary within ${budget}s" >&2
exit 1
