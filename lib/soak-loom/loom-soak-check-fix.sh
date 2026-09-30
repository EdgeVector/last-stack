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

command -v gh >/dev/null 2>&1 || exit 1
tip="$(gh api "repos/EdgeVector/$repo/git/ref/heads/main" --jq '.object.sha' 2>/dev/null || true)"
[ -n "$tip" ] || exit 1
# GitHub gate of record: the required `ci-required` check run must be green.
state="$(gh api "repos/EdgeVector/$repo/commits/$tip/check-runs?check_name=ci-required" \
  --jq '[.check_runs[] | select(.status == "completed") | .conclusion] | if index("success") then "success" else "other" end' 2>/dev/null || true)"
[ "$state" = "success" ]
