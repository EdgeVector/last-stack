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

require 'North Star → Milestone → cards' "$skill"
require 'never generate milestones automatically' "$skill"
require 'fkanban milestone add <slug>' "$skill"
require 'before any linked card' "$skill"
require '--driver last-stack-milestone-driver' "$skill"
require '--proof-card <terminal-slug>' "$skill"
require '--proof-status pending' "$skill"
require 'This two-step sequence is required' "$skill"
require '--milestone <slug>' "$skill"
require 'fkanban milestone reconcile <slug> --json' "$skill"
require 'fkanban milestone detail <slug> --json' "$skill"
require 'fkanban milestone groom --json' "$skill"
require 'A Brain North Star supplies durable intent but never auto-generates' "$playbook"
require 'Completion comes only from proof-gated milestone reconciliation' "$playbook"

printf 'ship-feature milestone contract: ok\n'
