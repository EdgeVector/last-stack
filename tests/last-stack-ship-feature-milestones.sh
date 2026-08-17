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

forbid() {
  local pattern="$1"
  local file="$2"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'forbidden ship-feature contract residue: %s in %s\n' "$pattern" "$file" >&2
    exit 1
  fi
}

require 'North Star → milestone → Kanban routine' "$skill"
require 'last-stack-design-pack' "$skill"
require 'must not kanban add cards' "$skill"
require '## MILESTONE_REQUEST' "$skill"
require 'slug=<milestone-slug>' "$skill"
require 'status=pending' "$skill"
require 'last-stack-ship-handoff' "$skill"
require 'eligible_for_claim: true' "$skill"
require 'routines run last-stack-north-star-driver' "$skill"
require 'NORTH_STAR_DRIVER_TARGET=<north-star-slug>' "$skill"
require 'MILESTONE_DRIVER_TARGET=<milestone-slug> routines run last-stack-milestone-driver' "$skill"
require 'The milestone routine—not' "$skill"
require 'kanban milestone detail <milestone-slug> --json' "$skill"
require 'kanban milestone groom --json' "$skill"
require '`last-stack-north-star-driver` converts one North Star outcome request' "$playbook"
require '`last-stack-milestone-driver` creates/links the milestone' "$playbook"
require "Completion comes only from the CLI's proof-gated milestone transition" "$playbook"
require 'eligible_for_claim: true' "$playbook"

# The one-liner is the silent-noop bug. It must not be the documented append form.
forbid 'MILESTONE_REQUEST slug=<milestone-slug> status=pending' "$skill"
forbid 'MILESTONE_REQUEST slug=<milestone-slug> status=pending' "$playbook"

printf 'ship-feature milestone contract: ok\n'
