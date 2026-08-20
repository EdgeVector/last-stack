#!/usr/bin/env bash
set -euo pipefail

# Guard the close-out skill's LastDB writes: file papercuts, write a full
# report of what was done, and update superseded brain records / stale
# kanban cards. Those preferences already exist
# (`preference-always-file-papercuts-in-brain`,
# `preference-always-save-to-brain-when-done`) but agents that only read
# skills/close-out/SKILL.md never saw them. Grep assertions over the skill
# (and the README index that points at it) so the steps cannot silently
# shrink back to "checkpoint a decision + file a card".

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$ROOT/skills/close-out/SKILL.md"
readme="$ROOT/README.md"
instructions="$ROOT/instructions/brain-kanban.md"

fail() { echo "closeout-skill-contract: $1" >&2; exit 1; }

[ -f "$skill" ] || fail "missing $skill"
[ -f "$readme" ] || fail "missing $readme"
[ -f "$instructions" ] || fail "missing $instructions"

# --- papercuts are a close-out step -----------------------------------------
grep -q '^## 4. File papercuts' "$skill" \
  || fail "close-out skill has no 'File papercuts' section"
grep -q 'default is FILE, not judge' "$skill" \
  || fail "close-out skill does not state the default is FILE, not judge"
grep -q 'brain papercut file' "$skill" \
  || fail "close-out skill does not show how to file a papercut"
grep -qi 'never file a papercut kanban card' "$skill" \
  || fail "close-out skill does not forbid papercut kanban cards"
grep -qi 'A mention is not a filing' "$skill" \
  || fail "close-out skill does not state that a mention is not a filing"
grep -q 'preference-always-file-papercuts-in-brain' "$skill" \
  || fail "close-out skill does not cite preference-always-file-papercuts-in-brain"

# --- the full brain report is a close-out step ------------------------------
grep -q '^## 5. Write the full closeout report to the brain' "$skill" \
  || fail "close-out skill has no full closeout-report section"
grep -q 'preference-always-save-to-brain-when-done' "$skill" \
  || fail "close-out skill does not cite preference-always-save-to-brain-when-done"
grep -q 'closeout-<YYYYMMDD>-' "$skill" \
  || fail "close-out skill does not show a closeout-YYYYMMDD report slug"
grep -q '## What was done' "$skill" \
  || fail "close-out skill report template is missing 'What was done'"
grep -q '## Papercuts filed' "$skill" \
  || fail "close-out skill report template is missing 'Papercuts filed'"
grep -q 'brain get closeout-' "$skill" \
  || fail "close-out skill does not require a point-get of the report"

# --- self-check cannot drop either write ------------------------------------
grep -q 'brain papercut file' "$skill" \
  || fail "close-out self-check lost the papercut file command"
grep -q 'full closeout report' "$skill" \
  || fail "close-out self-check does not require the full closeout report"

# --- the index that points agents at the skill -------------------------------
grep -q 'file session papercuts' "$readme" \
  || fail "README close-out blurb no longer mentions filing papercuts"
grep -q 'full brain report' "$readme" \
  || fail "README close-out blurb no longer mentions the full brain report"
grep -q 'superseded brain records' "$readme" \
  || fail "README close-out blurb no longer mentions superseded brain records"

# --- superseded-record pass is a close-out step -----------------------------
grep -q '^## 6. Update superseded brain records and stale kanban cards' "$skill" \
  || fail "close-out skill has no superseded-record section"
grep -q 'brain ask' "$skill" \
  || fail "close-out skill does not tell agents to brain ask for replaced facts"
grep -q 'Stale records updated' "$skill" \
  || fail "close-out skill report template is missing 'Stale records updated'"
grep -q 'last-stack-card-closeout' "$skill" \
  || fail "close-out skill does not tell agents how to close a merged Kind:pr card"
grep -q 'Never get→edit→put a large record' "$skill" \
  || fail "close-out skill does not forbid get→edit→put on large brain records"
if grep -q 'Every PR body carries a `## Proof` block' "$skill"; then
  fail "close-out skill still requires a PR-body ## Proof block (removed 2026-07-03)"
fi

# --- workspace contract agrees with typed decision writes -------------------
if grep -q 'Do NOT create `type: decision` records — that path is broken' "$instructions"; then
  fail "instructions/brain-kanban.md still forbids typed decision writes"
fi
grep -q 'type: decision' "$instructions" \
  || fail "instructions/brain-kanban.md does not instruct typed decision writes"
grep -q 'archived `decisions-log`' "$instructions" \
  || fail "instructions/brain-kanban.md does not name the archived decisions-log monolith"

# --- self-check cannot drop the superseded-record pass ----------------------
grep -q 'facts this session replaced' "$skill" \
  || fail "close-out self-check does not require the superseded-record pass"

# --- guard the guard --------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^## 4\. File papercuts/{f=1} /^## 5\./{f=0} !f' "$skill" \
  | awk '/^## 5\. Write the full closeout report/{f=1} /^## 6\./{f=0} !f' \
  | awk '/^## 6\. Update superseded brain records/{f=1} /^## 7\./{f=0} !f' \
  > "$tmp/stripped.md"
if grep -q 'brain papercut file' "$tmp/stripped.md" && \
   grep -q 'closeout-<YYYYMMDD>-' "$tmp/stripped.md"; then
  fail "self-check: stripping the new sections did not remove their rules, so these greps prove nothing"
fi
if grep -q '^## 4. File papercuts' "$tmp/stripped.md"; then
  fail "self-check: stripping did not remove the papercut section heading"
fi
if grep -q '^## 5. Write the full closeout report to the brain' "$tmp/stripped.md"; then
  fail "self-check: stripping did not remove the report section heading"
fi
if grep -q '^## 6. Update superseded brain records and stale kanban cards' "$tmp/stripped.md"; then
  fail "self-check: stripping did not remove the superseded-record section heading"
fi

echo "closeout-skill-contract: ok"
