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

# Factory contract (2026-08-26): loom ship-feature v4 is the engine; the
# legacy North Star → milestone pipeline survives only as the non-github
# venue fallback.
require 'loom run ship-feature --key <key>' "$skill"
require 'design-approval --payload' "$skill"
require 'Never signal an approval the user did not give' "$skill"
require 'last-stack-pr-venue <owner/repo> <repo-root>' "$skill"
require 'proof_command' "$skill"
require 'force_drift_until_rev' "$skill"
require 'ship-<feature-kebab>-<yyyymmdd>' "$skill"
require 'last-stack-design-pack' "$skill"
# Fallback pointers must survive so non-github venues still have a path.
require 'sop-feature-ship-loop' "$skill"
require 'last-stack-ship-handoff' "$skill"
require '## MILESTONE_REQUEST' "$skill"
require 'eligible_for_claim: true' "$skill"
require '`last-stack-north-star-driver` converts one North Star outcome request' "$playbook"
require '`last-stack-milestone-driver` creates/links the milestone' "$playbook"
require "Completion comes only from the CLI's proof-gated milestone transition" "$playbook"
require 'eligible_for_claim: true' "$playbook"

# The one-liner is the silent-noop bug. It must not be the documented append form.
forbid 'MILESTONE_REQUEST slug=<milestone-slug> status=pending' "$skill"
forbid 'MILESTONE_REQUEST slug=<milestone-slug> status=pending' "$playbook"

printf 'ship-feature milestone contract: ok\n'
