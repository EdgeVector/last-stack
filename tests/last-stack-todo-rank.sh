#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-todo-rank"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

chmod +x "$BIN"

cat >"$tmp/kanban" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAST_STACK_TODO_RANK_LOG:?}"
if [ "$1" = "rank" ]; then
  printf '[{"slug":"milestone-frontier","tier":"program"},{"slug":"papercut","tier":"papercut"}]\n'
  exit 0
fi
exit 9
SH
chmod +x "$tmp/kanban"

export LAST_STACK_TODO_RANK_LOG="$tmp/calls.log"
PATH="$tmp:/usr/bin:/bin" "$BIN" --json >"$tmp/out.json"

grep -q '"milestone-frontier"' "$tmp/out.json"
grep -q '^rank --board default --column todo --mode hard --json$' "$tmp/calls.log"

: >"$tmp/calls.log"
PATH="$tmp:/usr/bin:/bin" "$BIN" \
  --board-cli kanban \
  --board custom \
  --column backlog \
  --mode priority \
  --attempts 1 \
  --json >/dev/null

grep -q '^rank --board custom --column backlog --mode priority --json$' "$tmp/calls.log"

if PATH="$tmp:/usr/bin:/bin" "$BIN" --not-a-flag >/dev/null 2>"$tmp/err"; then
  echo "expected unknown flag to fail" >&2
  exit 1
fi
grep -q 'unknown argument' "$tmp/err"

echo "ok last-stack-todo-rank"
