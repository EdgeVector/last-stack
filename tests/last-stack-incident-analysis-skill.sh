#!/usr/bin/env bash
# Contract for the evidence-backed Five Whys incident analysis skill.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$root/skills/incident-analysis/SKILL.md"
readme="$root/README.md"

fail() {
  printf 'incident-analysis-skill-contract: %s\n' "$1" >&2
  exit 1
}

require() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

[ -f "$skill" ] || fail "missing $skill"
[ -f "$readme" ] || fail "missing $readme"

grep -q '^name:[[:space:]]*incident-analysis$' "$skill" \
  || fail "frontmatter name is not incident-analysis"
grep -q '^description:' "$skill" \
  || fail "frontmatter missing description"

for trigger in \
  'what happened' \
  'incident analysis' \
  'postmortem' \
  'root cause analysis' \
  'five whys' \
  '5 whys'; do
  require "$trigger" "$skill"
done

require 'situations notices --since 1h' "$skill"
require 'brain ask "<failure signature and affected component>"' "$skill"
require 'Do not use `brain list` as a census.' "$skill"
require 'Would this evidence look different if the cause were false?' "$skill"

for field in '**Question:**' '**Answer:**' '**Evidence:**' '**Confidence:**' '**Disproof:**'; do
  require "$field" "$skill"
done

for why in 1 2 3 4 5; do
  require "### Why $why" "$skill"
done

require 'Do not invent' "$skill"
require 'answer to complete the count.' "$skill"
require 'Do not use `human error` as the root cause.' "$skill"
require 'Root cause: unknown' "$skill"
require '| Cause or gap | Action | Owner | Proof | Status |' "$skill"
require 'use the `fix-it` skill after this analysis' "$skill"
require 'Do not restart a shared service or change live state without authority.' "$skill"

grep -q '| \*\*incident-analysis\*\*' "$readme" \
  || fail "README skills table has no incident-analysis row"

why_count="$(grep -Ec '^### Why [1-5]$' "$skill")"
[ "$why_count" -eq 5 ] \
  || fail "required report must contain five numbered why entries, got $why_count"

printf 'incident-analysis-skill-contract: ok\n'
