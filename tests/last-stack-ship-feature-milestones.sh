#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
skill="$root/skills/ship-feature/SKILL.md"
playbook="$root/skills/ship-feature/references/loop-playbook.md"

require() {
  local pattern="$1"
  local file="$2"
  if ! grep -Fq -- "$pattern" "$file"; then
    printf 'missing ship-feature milestone contract: %s in %s\n' "$pattern" "$file" >&2
    exit 1
  fi
}

require 'North Star → milestone → Kanban routine' "$skill"
require 'must not directly create milestones or Kanban' "$skill"
require 'MILESTONE_REQUEST slug=<milestone-slug> status=pending' "$skill"
require 'routines run last-stack-north-star-driver' "$skill"
require 'NORTH_STAR_DRIVER_TARGET=<north-star-slug>' "$skill"
require 'MILESTONE_DRIVER_TARGET=<milestone-slug> routines run last-stack-milestone-driver' "$skill"
require 'The routine—not Ship It—creates' "$skill"
require 'The milestone routine—not' "$skill"
require 'fkanban milestone detail <milestone-slug> --json' "$skill"
require 'fkanban milestone groom --json' "$skill"
require '`last-stack-north-star-driver` converts one North Star outcome request' "$playbook"
require '`last-stack-milestone-driver` creates/links the milestone' "$playbook"
require 'Completion comes only from proof-gated milestone reconciliation' "$playbook"

printf 'ship-feature milestone contract: ok\n'
