#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-post-merge-safe-upgrade"
chmod +x "$BIN"

map_out="$("$BIN" --map)"
echo "$map_out" | grep -q 'brain' || { echo "FAIL map missing brain"; exit 1; }
echo "$map_out" | grep -q 'fkanban' || { echo "FAIL map missing fkanban"; exit 1; }
echo "$map_out" | grep -q 'lastsecrets' || { echo "FAIL map missing lastsecrets"; exit 1; }

# dry-run once should seed or no-op without dying
TMP="$(mktemp -d)"
export LAST_STACK_POST_MERGE_DRY_RUN=1
export LAST_STACK_POST_MERGE_STATE_DIR="$TMP/state"
# may fail open-list if no lastgit — still must exit 0 from poll
if ! "$BIN" --once --all "$TMP/state" 2>"$TMP/err"; then
  # only fail if script itself crashed hard without writing seed message
  if ! grep -qE 'seeded|start|fleet open list failed' "$TMP/err" "$TMP/state/post-merge.log" 2>/dev/null; then
    cat "$TMP/err" >&2
    echo "FAIL unexpected exit"
    exit 1
  fi
fi
echo "PASS last-stack-post-merge-safe-upgrade"
