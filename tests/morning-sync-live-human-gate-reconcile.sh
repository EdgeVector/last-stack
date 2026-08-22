#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

required_files=(
  "$ROOT/routines/morning-sync.md"
  "$ROOT/skills/morning-sync/SKILL.md"
  "$ROOT/routines/human-gate-audit.md"
)

for file in "${required_files[@]}"; do
  grep -q 'Never hard-code or require a dated human-gate' "$file" \
    || { echo "missing dated-snapshot guard: $file" >&2; exit 1; }
  grep -qi 'point-read' "$file" \
    || { echo "missing live point-read rule: $file" >&2; exit 1; }
done

if grep -Eqi 'reference-morning-sync-human-gate-state-20[0-9]{6}' \
  "$ROOT/routines/morning-sync.md" \
  "$ROOT/skills/morning-sync/SKILL.md" \
  "$ROOT/routines/human-gate-audit.md"; then
  echo "morning-sync source hard-codes a dated human-gate state slug" >&2
  exit 1
fi

grep -q 'read `backlog`, `todo`, and `doing`' "$ROOT/routines/morning-sync.md" \
  || { echo "morning-sync still names a retired board column" >&2; exit 1; }

echo "ok morning-sync reconciles live human-gate state"
