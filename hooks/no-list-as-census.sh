#!/usr/bin/env bash
# PreToolUse hook. Blocks list-as-census reads against LastDB-backed CLIs.
#
# WHY: LastDB is Dynamo-style — Get O(1), range-under-hash O(log M), no scan
# (concepts-lastdb-agent-access-model). `--list` is the verb agents reach for
# when they want "what exists?", and it is the one shape the DB does not
# support. Prose in CLAUDE.md has not held: agents default to it, hit the
# papercut, then re-enforce it in a later session. This is the wall.
#
# Tom's rule (2026-08-06, a won't-undo in ~/.claude/CLAUDE.md):
#   "If you need something from brain, you should be using brain search."
#
# ESCAPE HATCH: a genuine census (e.g. last-stack-north-star-ledger-sync — "which
# projects exist" is not a top-k question) passes by putting a marker with a
# reason in the command:
#     brain list --type project --json  # census-ok: NS ledger sync needs closed set
# The marker is deliberately greppable so deliberate uses stay auditable.
#
# Every deny below MUST hand back a verbatim runnable replacement. An error that
# only names the violation teaches nothing; an error that ends in a command the
# agent can copy into the next tool call is the only thing that reaches it at
# the moment it is wrong.
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"

emit_deny() {
  # Deny only — never "continue": false. Halting killed whole agent turns on
  # every violation (Tom, 2026-07-18); deny alone lets the agent retry
  # compliantly in the same turn.
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null && exit 0
  printf '%s\n' "$reason" >&2
  exit 2
}

# ---------------------------------------------------------------- MCP surface
# mcp__brain__brain_list is the same banned verb with a different spelling.
case "$tool" in
  *brain_list)
    emit_deny "BLOCKED: brain_list is not a census instrument.

LastDB is Dynamo-style: no scan. \`list\` has no completeness contract and is not
getting one (Tom, 2026-08-06).
A day on which it measures complete is not permission to sweep on it.

Use instead, in order of preference:
  mcp__brain__brain_ask     { question: \"<what you actually want to know>\" }
  mcp__brain__brain_search  { query: \"<terms>\", type: \"<type>\" }
  mcp__brain__brain_get     { slug: \"<known-slug>\" }

For a closed set: brain_get a known seed, then crawl its linked_from with more
brain_get calls. That is authoritative; list is not.

If you genuinely need a census, use the CLI with an audited reason:
  brain list --type <T> --json  # census-ok: <why a top-k answer will not do>"
    ;;
esac

[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

# Audited escape hatches. Both require a reason after the colon.
#   census-ok:    a genuine census — a top-k answer will not do.
#   lint-fixture: the banned string is DATA, not a call — writing a test
#                 fixture, a lint rule, or documentation that quotes the
#                 pattern. Found by dogfooding: this hook blocked its own
#                 test-fixture authoring, and a guardrail that blocks writing
#                 tests for it is one that gets switched off.
printf '%s' "$cmd" | grep -qE '(census-ok|lint-fixture):[[:space:]]*[^[:space:]]' && exit 0

# Command-position prefix: start of line, after a separator, or inside $( ).
#
# NO BACKTICK ALTERNATIVE. It used to carry one, for legacy ` ` command
# substitution, and that one character made all three rules below fire on
# MARKDOWN INLINE CODE -- which is how every brain record, closeout and commit
# message in this workspace writes a command name. Measured 2026-10-03 with the
# matcher copied verbatim into a probe:
#
#   "Do not use `brain list` as a census."                DENIED  (rule 2 has no
#   "Do not use brain list as a census."                  allowed  second token,
#   "| `brain count` | under-reports |"                   DENIED   so the prefix
#   brain list --type papercut                            DENIED   alone decides)
#
#   prose `situations list --json` + an --all elsewhere   DENIED
#   the same prose with no --all anywhere                 allowed
#   the same prose without backticks, plus an --all       allowed
#
# So an agent could not write down the very rule this hook enforces, through the
# tool the rule is about: a `brain put` heredoc explaining why list is not a
# census was denied, and the denial kills the WHOLE Bash call, so the heredoc
# that was supposed to create the file never ran either. The patch that removes
# this alternative was itself denied by it, twice.
#
# Dropping the alternative loses only backtick command substitution, which this
# workspace's own shell guidance already forbids in favour of $( ) and which the
# `heredoc-backticks` and `dquote-backticks` rules in
# last-stack-routine-shell-lint already reject outright. So the shape it was
# protecting is one another guard refuses first.
# papercut-hook-situations-list-all-matches-both-tokens-anywhere-in-the-bash-call-20261003
PRE='(^|[;&|][[:space:]]*|\$\([[:space:]]*)'

# ------------------------------------------------------- situations list --all
# Known dead: sends an unfiltered query the node's no-scan guard 400s, and the
# CLI mistranslates the 400 as "Could not reach LastDB node" — a false outage
# that has already sent agents into doctor/restart loops.
if printf '%s' "$cmd" | grep -qE "${PRE}(situations|[^[:space:]]*/situations)[[:space:]]+list\b" \
  && printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--all([[:space:]]|$|=)'; then
  emit_deny "BLOCKED: \`situations list --all\` is dead, not slow.

It drops the status filter and sends an unfiltered query. The node's no-scan
guard correctly rejects it with full_schema_scan_not_allowed — then the CLI
prints \"Could not reach LastDB node\", which reads as an outage. The node is
healthy. Do NOT escalate, doctor, or restart anything.

Run instead:
  situations list --json          # the active set — this works
  situations show <slug>          # resolves a specific Situation, incl. resolved ones

Tracked: card lastdb-tooling-false-failure-on-designed-or-transient-states"
fi

# -------------------------------------------------------------- brain list
if printf '%s' "$cmd" | grep -qE "${PRE}(f?brain|[^[:space:]]*/f?brain)[[:space:]]+(list|count)\b"; then
  emit_deny "BLOCKED: brain list/count is not a census instrument.

LastDB is Dynamo-style — Get O(1), range-under-hash O(log M), no scan
(concepts-lastdb-agent-access-model). \`brain list\` has no completeness
contract and is not getting one (Tom, 2026-08-06). Its {items,total,truncated}
envelope is an honesty signal, not a promise. \`--count\` over-reports: soft-deleted
rows keep their RecordListEntry. And \`--type papercut\` cannot be listed at all
(the status-keyed index is not registered) — a type sweep silently omits the
entire defect ledger.

Run instead:
  brain ask \"<the question you actually have>\"     # best: hybrid BM25 + vector
  brain search \"<terms>\" --type <T>                # discovery sample
  brain get <slug>                                  # authoritative for a known slug

For a closed set: \`brain get\` a known seed, then crawl its linked_from with
targeted gets. That is the authoritative completeness check.

If a top-k answer genuinely will not do, state why and it passes:
  brain list --type <T> --json  # census-ok: <reason>

If the command text is DATA (quoted as evidence in a brain/papercut body, or a
test fixture) and not a call, mark it and it passes:
  ... # lint-fixture: <why this is data, not a call>"
fi

# -------------------------------------------------------------- kanban list
# NOT a no-scan issue: `kanban list` reads BoardCards HashRange under the board,
# so even `--all` is a bounded partition read (O(log M)). Board-wide sweeps like
# last-stack-card-reaper-run and last-stack-north-star-dashboard legitimately
# need it. Do NOT block --all — over-blocking a legitimate shape is how a
# guardrail gets switched off, and then nothing is guarded.
# The expensive shape is --full-body: it hydrates EVERY card body on top of the
# partition read, which is what CLAUDE.md bans in routines.
if printf '%s' "$cmd" | grep -qE "${PRE}(kanban|fkanban|[^[:space:]]*/f?kanban)[[:space:]]+list\b" \
  && printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--full[-_]body([[:space:]]|$|=)'; then
  emit_deny "BLOCKED: kanban list --full-body.

The partition read is fine; hydrating every card body on top of it is not.
CLAUDE.md bans this shape in routines and it is a top node consumer under load.

Run instead:
  kanban list --column todo --json    # keyed, body-free previews
  kanban list --all --json            # whole board, still body-free — ALLOWED
  kanban show <slug> --json           # the ONE card you need, with its full body
  kanban search \"<text>\" --json       # when you do not know the column

If you genuinely need every body in one call, say why:
  kanban list --full-body --json  # census-ok: <reason>

If the command text is DATA (quoted as evidence in a brain/papercut body, or a
test fixture) and not a call, mark it and it passes:
  ... # lint-fixture: <why this is data, not a call>"
fi

exit 0
