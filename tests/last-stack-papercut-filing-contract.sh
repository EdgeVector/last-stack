#!/usr/bin/env bash
set -euo pipefail

# The PRODUCER half of the papercut pipeline.
#
# `last-stack-papercut-reconciler-contract.sh` guards the consumer: the one
# routine allowed to turn papercuts into cards. Nothing guarded the producer,
# and the consequence was measurable — the shared routine contract that every
# routine cites for heartbeat, dedupe, guardrails and shell discipline said
# NOTHING about filing papercuts, so an agent that read only the contract (which
# is the contract's whole purpose) never learned the rule. Roughly a quarter of
# routine prompts carried their own wording for it; the rest carried none.
#
# These are grep assertions over prose on purpose. The rules below are the ones
# that were broken in practice, not a summary of the section.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
contract="$ROOT/templates/routine-fleet/sop-routine-shared-contract.md"
config="$ROOT/templates/routine-fleet/workspace-config.md"
portal="$ROOT/share/portal-template/AGENTS.md"
# The widest surface by far: `setup` upserts this file as a managed block into
# ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.factory/AGENTS.md and
# ~/.config/opencode/AGENTS.md, so it is what EVERY agent on EVERY harness reads
# at session start. A rule missing here is a rule most agents never see.
instructions="$ROOT/instructions/brain-kanban.md"

fail() { echo "papercut-filing-contract: $1" >&2; exit 1; }

for f in "$contract" "$config" "$portal" "$instructions"; do
  [ -f "$f" ] || fail "missing $f"
done

# --- the globally-injected instructions carry the rule -----------------------
grep -q '^### ALWAYS file papercuts' "$instructions" \
  || fail "instructions/brain-kanban.md has no papercut-filing section"
grep -q 'default is FILE, not judge' "$instructions" \
  || fail "instructions/brain-kanban.md does not state the default is FILE, not judge"
grep -q 'brain papercut file' "$instructions" \
  || fail "instructions/brain-kanban.md does not show how to file one"
grep -qi 'never file a papercut kanban card' "$instructions" \
  || fail "instructions/brain-kanban.md does not forbid papercut kanban cards"
grep -qi 'A mention is not a filing' "$instructions" \
  || fail "instructions/brain-kanban.md does not state that a mention is not a filing"
grep -qi 'Burying a finding in a record you then CLOSE' "$instructions" \
  || fail "instructions/brain-kanban.md does not warn about burying a finding in a closed record"

# `setup` is the only thing that propagates that file. If the upsert is renamed
# or dropped, the section above still exists and reaches nobody — the exact
# detector-with-no-generator shape this whole change is about.
grep -q 'instructions/brain-kanban.md' "$ROOT/setup" \
  || fail "setup no longer sources instructions/brain-kanban.md, so the rule reaches no harness"
grep -q 'instructions/asd-ste100.md' "$ROOT/setup" \
  || fail "setup no longer sources instructions/asd-ste100.md, so STE reaches no harness"
for harness_file in '.claude/CLAUDE.md' '.codex/AGENTS.md'; do
  grep -q "$harness_file" "$ROOT/setup" \
    || fail "setup no longer upserts the managed block into $harness_file"
done

# --- the shared contract carries the section ---------------------------------
grep -q '^## 5\. File papercuts' "$contract" \
  || fail "shared contract has no 'File papercuts' section"

# The default. This is the rule agents break first: they decide a finding is not
# important enough instead of filing it.
grep -q 'default is FILE, not judge' "$contract" \
  || fail "contract does not state that the default is FILE, not judge"

# Brain only. A papercut card filed directly bypasses the reconciler's dedupe.
grep -qi 'never straight to the board' "$contract" \
  || fail "contract does not forbid filing papercuts straight to the board"

# Search first, and treat a hit as a remedy rather than only as a duplicate.
grep -q 'Search before you file' "$contract" \
  || fail "contract does not require searching before filing"

# The two failure modes that make a finding look filed when it is not.
grep -q 'A mention is not a filing' "$contract" \
  || fail "contract does not state that a mention is not a filing"
grep -qi 'Burying a finding inside a record you then CLOSE' "$contract" \
  || fail "contract does not warn about burying a finding in a record you close"

# --- portability: every placeholder the section uses must be declarable -------
# The contract's own Validation section promises a routine can run "without
# copying project constants into its prompt". A placeholder the bootstrap kit
# does not declare breaks that promise silently — the operator has nowhere to
# fill it in, so it ships to agents as a literal <ANGLE_BRACKET> string.
section="$(awk '/^## 5\. File papercuts/{f=1} /^## 6\./{f=0} f' "$contract")"
[ -n "$section" ] || fail "could not extract the papercut section"

placeholders="$(printf '%s\n' "$section" | grep -o '<[A-Z][A-Z0-9_]*>' | sort -u)"
[ -n "$placeholders" ] || fail "papercut section declares no placeholders at all"

while read -r ph; do
  [ -n "$ph" ] || continue
  grep -q -- "$ph" "$config" \
    || fail "placeholder $ph is used in the contract but not declared in workspace-config.md"
done <<<"$placeholders"

# --- the portal rule ---------------------------------------------------------
# Portal agents are interactive and do not read the routine contract, so the
# rule has to exist in both places or half the fleet never sees it.
grep -qi 'File a papercut for every piece of friction' "$portal" \
  || fail "portal AGENTS.md does not tell agents to file papercuts"
grep -qi 'A mention is not a filing' "$portal" \
  || fail "portal AGENTS.md does not state that a mention is not a filing"

# --- guard the guard ---------------------------------------------------------
# A grep suite is only worth its runtime if it can fail. Prove each family of
# assertion actually discriminates, against a copy with the section removed.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^## 5\. File papercuts/{f=1} /^## 6\./{f=0} !f' "$contract" > "$tmp/stripped.md"
if grep -q 'default is FILE, not judge' "$tmp/stripped.md"; then
  fail "self-check: stripping the section did not remove its rules, so these greps prove nothing"
fi

echo "papercut-filing-contract: ok"
