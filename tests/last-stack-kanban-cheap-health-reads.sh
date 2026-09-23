#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

grep -q 'Preflight with the cheap socket health check `kanban ping`' \
  "$ROOT/routines/north-star-hygiene.md"
grep -q '`kanban ping`' "$ROOT/routines/dogfood-rotate.md"
grep -q '^kanban ping >/dev/null 2>&1$' \
  "$ROOT/routines/ship-pipeline-gap-audit.md"
grep -q 'socket health check `kanban ping`' \
  "$ROOT/routines/north-star-rollup.md"
grep -q 'kanban ping >/dev/null' "$ROOT/bin/last-stack-safe-upgrade-cli"

if grep -n -E 'kanban (list|pickup status)' \
  "$ROOT/routines/north-star-hygiene.md" \
  "$ROOT/routines/dogfood-rotate.md" \
  "$ROOT/routines/north-star-rollup.md"; then
  echo "FAIL: health-only routine preflights still use a BoardCards-backed read" >&2
  exit 1
fi

echo "ok cheap kanban health reads"
