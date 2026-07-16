#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"

LAST_STACK_ROOT="$ROOT" "$ROOT/setup" --host claude >"$tmp/setup.out"

for skill in fkanban-card-authoring fkanban-grooming; do
  installed="$HOME/.claude/skills/$skill/SKILL.md"
  if [ ! -f "$installed" ]; then
    echo "FAIL: missing installed compat skill: $installed" >&2
    cat "$tmp/setup.out" >&2
    exit 1
  fi

  if ! grep -q "^name: $skill$" "$installed"; then
    echo "FAIL: installed compat skill has wrong name: $installed" >&2
    sed -n '1,8p' "$installed" >&2
    exit 1
  fi
done

grep -q "kanban skill" "$HOME/.claude/skills/fkanban-card-authoring/SKILL.md" || {
  echo "FAIL: fkanban-card-authoring shim does not point at kanban" >&2
  exit 1
}

grep -q "kanban-grooming" "$HOME/.claude/skills/fkanban-grooming/SKILL.md" || {
  echo "FAIL: fkanban-grooming shim does not point at kanban-grooming" >&2
  exit 1
}

echo "ok"
