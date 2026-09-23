#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
watch="$ROOT/routines/kanban-watch.md"

grep -q 'kanban list --column doing --json' "$watch"
grep -q 'kanban groom board-cards-heal --apply "\${heal_args\[@\]}"' "$watch"
grep -q 'groom-board.*full audit\|full audit.*groom-board' "$watch"

if grep -q '^kanban groom board-cards-heal --apply$' "$watch"; then
  echo "FAIL: kanban-watch must not run the unscoped BoardCards heal" >&2
  exit 1
fi

echo "ok kanban-watch targeted BoardCards heal"
