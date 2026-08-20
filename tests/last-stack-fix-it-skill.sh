#!/usr/bin/env bash
# Contract for skills/fix-it/SKILL.md: the four predicates, anti-fix table,
# mandatory final-state report, and handoff to kanban-agent must stay in the
# skill body. A skill that only says "don't bandage" is not this skill.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$root/skills/fix-it/SKILL.md"
readme="$root/README.md"

fail() {
  printf 'fix-it-skill-contract: %s\n' "$1" >&2
  exit 1
}

[ -f "$skill" ] || fail "missing $skill"
[ -f "$readme" ] || fail "missing $readme"

require() {
  local pattern="$1"
  local file="$2"
  if ! grep -Fq -- "$pattern" "$file"; then
    fail "missing '$pattern' in $file"
  fi
}

grep -q '^name:[[:space:]]*fix-it$' "$skill" \
  || fail "frontmatter name is not fix-it"
grep -q '^description:' "$skill" \
  || fail "frontmatter missing description"

# Four predicates that define a permanent fix.
require '**Producer.**' "$skill"
require '**Class.**' "$skill"
require '**Residue.**' "$skill"
require '**Live signal.**' "$skill"
require 'If any predicate fails, you have a temporary repair.' "$skill"

# Anti-fixes that agents otherwise ship as "the fix".
require 'Retry / sleep / "try again" around a flaky producer' "$skill"
require 'Downstream check that catches this one instance' "$skill"
require 'File a papercut and walk away' "$skill"
require 'A mention is not a filing, and a filing is not a fix' "$skill"

# Bleed-stop is allowed and is not the deliverable.
require 'Bleed-stop is allowed. It is not the deliverable.' "$skill"
require 'TEMPORARY:' "$skill"
require 'EXPIRES:' "$skill"

# Mandatory user-visible report shape: final state first.
require 'Present the final state (mandatory)' "$skill"
require '## Final state' "$skill"
require '## Recurrence test' "$skill"
require 'Lead with what is true after the fix.' "$skill"

# Handoffs: this skill does not own merge, factory stall, or papercut cards.
require 'why-shipping-stopped' "$skill"
require 'kanban-agent' "$skill"
require 'Do not invent a' "$skill"
require 'Never file a papercut kanban card' "$skill"
require 'Do not run `brain list` as a census.' "$skill"

# Live original signal, not fixture-only CI.
require 'Green CI on a fixture is not enough.' "$skill"
require 'Live symptom recheck' "$skill"

# README index so agents can find it without already knowing the name.
grep -q '| \*\*fix-it\*\*' "$readme" \
  || fail "README skills table has no fix-it row"
grep -q "what's the permanent fix" "$readme" \
  || fail "README no longer tells agents to use fix-it for 'what is the permanent fix'"

# Guard the guard: stripping the four-predicate section must drop the
# producer/class/residue/live-signal headings, else these greps prove nothing.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^## Permanent fix \(all four must hold\)/{f=1} /^## Not this skill/{f=0} !f' "$skill" \
  > "$tmp/stripped.md"
if grep -q '\*\*Producer\.\*\*' "$tmp/stripped.md" && \
   grep -q '\*\*Live signal\.\*\*' "$tmp/stripped.md"; then
  fail "self-check: stripping the four-predicate section did not remove it"
fi

printf 'fix-it-skill-contract: ok\n'
