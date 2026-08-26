#!/usr/bin/env bash
# REPORT: three red attempts — only now does the failure need a human. Page
# with the attempt history; the P0 card stays open with everything recorded.
set -euo pipefail

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
digest="$(printf '%s' "$input" | jq -r '.digest // empty')"
card="$(printf '%s' "$input" | jq -r '.card // empty')"
notes="$(printf '%s' "$input" | jq -r '.attempt_notes // "no attempt notes"')"

msg="soak heal exhausted: $app ${digest:0:12} still RED after 3 fix attempts. Card: ${card:-unfiled}. $notes"
echo "soak-report $msg"

if [ "${LOOM_LIVE:-}" = "1" ] || [ "${LOOM_SOAK_HEAL_LIVE:-}" = "1" ]; then
  if command -v ra >/dev/null 2>&1; then
    ra notify "$msg" --priority high || true
  fi
fi
exit 0
