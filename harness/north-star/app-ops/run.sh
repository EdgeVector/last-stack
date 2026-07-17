#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-app-ops-latency
MODE="$(ns_mode)"

ns_require_cmd lastdb

set +e
help_out="$(lastdb ops --help 2>&1)"
help_rc=$?
set -e
if [ "$help_rc" -ne 0 ] || ! printf '%s\n' "$help_out" | grep -q -- '--by-app'; then
  ns_write_report "$SLUG" FAIL "lastdb ops missing or lacks --by-app\n\`\`\`\n$help_out\n\`\`\`" || exit 1
  exit 1
fi

# Generate a little load via brain/kanban if available so ops is non-empty
if command -v kanban >/dev/null 2>&1; then
  kanban list --column todo --json >/dev/null 2>&1 || true
fi

set +e
ops_out="$(lastdb ops --by-app 2>&1 | head -80)"
ops_rc=$?
set -e
notes="$(printf 'lastdb ops --by-app rc=%s\n```\n%s\n```\n' "$ops_rc" "$ops_out")"
if [ "$ops_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$notes" || exit 1
  exit 1
fi

# Soft signal: prefer seeing non-unknown clients when live traffic exists
verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
if printf '%s\n' "$ops_out" | grep -qi 'unknown' && ! printf '%s\n' "$ops_out" | grep -qiE 'kanban|brain|lastgit'; then
  notes="$(printf '%s\nWARN: only unknown clients visible — fleet self-ID may be incomplete\n' "$notes")"
fi
ns_write_report "$SLUG" "$verdict" "$(printf 'App×verb ops surface works (lastdb ops --by-app).\n\n%s\n' "$notes")"
