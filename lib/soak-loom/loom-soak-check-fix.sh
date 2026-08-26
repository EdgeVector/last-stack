#!/usr/bin/env bash
# check for FIX: did anything new land on the app repo's main since the red
# digest was published? Stand-in accepts; live checks the repo tip moved.
set -euo pipefail

if [ "${LOOM_LIVE:-}" != "1" ] && [ "${LOOM_SOAK_HEAL_LIVE:-}" != "1" ]; then
  exit "${LOOM_CHECK_EXIT:-0}"
fi

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
[ -n "$app" ] || exit 1
repo="$app"
[ "$repo" = "kanban" ] && repo="fkanban"

command -v lastgit >/dev/null 2>&1 || exit 1
tip="$(lastgit ref "$repo" main 2>/dev/null | awk '{print $1}')"
[ -n "$tip" ] || exit 1
state="$(lastgit ci status "$tip" --repo "$repo" --json 2>/dev/null | jq -r '.state // empty')"
[ "$state" = "success" ]
