#!/usr/bin/env bash
# Contract: last-stack docs teach the live CLI flags agents keep inventing wrong.
# Window 2026-09-03/04 self-improvement-loop: situations notice --body (11
# sessions), kanban rank --top (3), kanban move --block-status (8), brain
# append --body/--body-path (18).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$root/skills/kanban/SKILL.md"
closeout="$root/skills/close-out/SKILL.md"
instructions="$root/instructions/brain-kanban.md"

fail() {
  printf 'cli-flag-gotchas-docs: %s\n' "$1" >&2
  exit 1
}

require() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

[ -f "$skill" ] || fail "missing $skill"
[ -f "$closeout" ] || fail "missing $closeout"
[ -f "$instructions" ] || fail "missing $instructions"

require 'situations notice' "$instructions"
require '--summary' "$instructions"
require "Unknown option '--body'" "$instructions"

require 'kanban rank' "$skill"
require "Unknown option '--top'" "$skill"
require 'kanban move <slug> <column> --position N' "$skill"

require 'kanban set <slug> --block-status' "$skill"
require 'move' "$skill"
require '--block-status' "$instructions"
require 'kanban rank <slug> --top' "$instructions"

require 'Append has no `--body` and no `--body-path`' "$instructions"
require 'stdin only — no `--body`' "$closeout"

echo "ok last-stack-cli-flag-gotchas-docs"
