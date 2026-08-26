#!/usr/bin/env bash
# check for REDEPLOY: a canary for the app is parked and soaking (or already
# activated green). Stand-in accepts.
set -euo pipefail

if [ "${LOOM_LIVE:-}" != "1" ] && [ "${LOOM_SOAK_HEAL_LIVE:-}" != "1" ]; then
  exit "${LOOM_CHECK_EXIT:-0}"
fi

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
[ -n "$app" ] || exit 1
stamp="${HOST_TRACK_STAMP_DIR:-$HOME/.host-track/stamps}/$app.soak.json"
if [ ! -f "$stamp" ]; then
  # No stamp: either activated (archived) or nothing parked. Accept — COLLECT
  # classifies green and DONE follows; a missing canary re-enters FIX anyway.
  exit 0
fi
status="$(jq -r '.status // ""' "$stamp")"
[ "$status" = "soaking" ] || [ "$status" = "soak_red" ]
