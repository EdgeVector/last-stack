---
name: session-miner
description: |
  Mine recent agent session JSONL transcripts with a named extractor profile.
  Use when a routine asks to scan the last N hours of sessions for papercuts,
  incidents/prevention, owner-stated durable knowledge, or agent-tooling
  improvement opportunities, then either report findings or write the profile's
  outputs to kanban/brain/tooling.
---

# Session Miner

Session Miner is a generic engine for routines that scan recent agent session
transcripts and turn repeated signals into durable outputs. Invoke it with a
profile name and a time window:

```text
profile=<papercuts|incidents|owner-statements|friction-patterns>
window_hours=<N, default 24>
mode=<report-only|apply, default report-only>
project=<workspace key or absolute workspace root, optional>
```

`report-only` never writes brain, kanban, source files, settings, or routine
prompts. `apply` performs the writes declared by the selected profile, after
dedupe and safety checks.

## Start

1. Fetch and honor the shared routine contract:
   `brain get sop-routine-shared-contract --type sop`. It owns heartbeat,
   primary-brain safety, card filing shape, dedupe, shell discipline, and
   verify-vs-origin-main rules.
2. Resolve project paths from `workspace-config` while that interim shim exists;
   if it is absent, use the explicit `project=` argument or the current
   workspace root. Do not hard-code EdgeVector paths in the reasoning. A future
   F-Config source may replace the brain shim; accept whichever config source
   the routine provides.
3. Resolve the transcript directory from config. For Claude Code projects this
   is usually `~/.claude/projects/<encoded-project>/`. Treat file mtimes as
   advisory only: filter sessions by the JSONL line `timestamp` field.
4. Load the extractor profile. Prefer `brain get miner-profile-<profile>`
   when that record exists; otherwise use the embedded reference profiles below.
   A brain profile may override: profile name, purpose, input selectors,
   candidate rules, dedupe keys, output destination, output template, and apply
   limits.
5. Read transcript JSONL structurally. Do not search raw transcript prose for
   failure keywords. Parse JSONL records, then inspect typed fields such as
   user-authored text, assistant text, tool_use names, and tool_result blocks.
   For command failures and routine failures, use `is_error` tool_result blocks
   and their structured command/output context. This avoids self-contamination
   from prompts that mention error words as examples.

## Transcript Handling

For each transcript file, build a compact session summary:

- Session id, transcript path, first and last timestamp inside the selected
  window.
- Genuine owner/user-authored messages. Exclude tool_result blocks and harness
  noise such as command wrappers, system reminders, scheduled-task wrappers,
  stop-hook feedback, interruption notices, and local command echoes.
- Tool failures from `tool_result` blocks where `is_error` is true, including
  command/tool name, short output excerpt, and nearby retry/correction context.
- Explicit corrections or constraints from the owner, with enough surrounding
  assistant context to understand what changed.
- Repeated manual workflows, repeated permission prompts, repeated retries with
  small command variations, and stale-doc/deprecation corrections.

Keep evidence small and specific: session id/path plus timestamp, recurrence
count, and a short paraphrase. Do not quote long transcript passages.

## Shared Triage

Every profile uses the same triage pass:

- Cluster candidates by root cause, not by wording. One bad CLI flag repeated in
  three sessions is one candidate, not three.
- Prefer repeated patterns across multiple sessions or across days. A severe
  one-off may still qualify for incidents, but routine papercuts and tooling
  improvements should normally recur.
- Dedupe before writing. Check live kanban cards, open PRs at the repo venue,
  active card branches/worktrees by exact slug/area, recently merged PRs, and
  any profile ledger. For brain outputs, search first and update in place
  instead of creating near-duplicates.
- In `report-only`, produce the exact writes that would be made, including
  proposed card slugs or brain slugs, but do not perform them.
- In `apply`, write only the selected profile's declared outputs. Do not ship
  product code from a mining run unless the profile explicitly allows agent
  tooling edits.

## Embedded Reference Profiles

### `papercuts`

Source routine: `daily-agent-papercut-sweep`.

Purpose: Find dev-process friction that should become kanban cards.

Candidate signals:

- Commands that fail and are retried with a small tweak.
- Permission-prompt friction that blocks normal unattended work.
- Agents hunting for the right file, script, endpoint, repo, or checkout.
- Owner corrections such as "that is deprecated; use X" or "do not do Y".
- Flaky or hanging tests, confusing CLI output, stale docs, or repeated manual
  setup.

Output in `apply`: one kanban card per actionable papercut, usually `todo`.
Use the shared contract card body. Include evidence, recurrence count, suggested
fix, and a concrete VERIFY line. File ambiguous or large fixes to `backlog`.

Skip: one-off mistakes, already-known cards, already-merged fixes that still
pass on current main, and product bugs better covered by a more specific
incident or feature card.

### `incidents`

Source routine: `daily-retro-prevention`.

Purpose: Rank the biggest things that bit the project in the window and attach
durable prevention.

Candidate signals:

- Repeated `is_error` tool_results across sessions.
- Failed scheduled routines, wedged watchers, reverted or force-closed PRs,
  red main checks, release blockers, or repeated CI churn.
- Cards moved into blocked/review because a process failed.

Output in `apply`: update a dated retro record and the prevention ledger, then
write the cheapest durable prevention for each top bite: brain SOP/concept for
process knowledge, kanban card for code/tooling guardrails, or routine prompt
fix card when the routine itself caused the bite.

Skip: trivia that cost minutes, Sentry re-triage already handled by a dedicated
Sentry routine, and prevention that requires a human product or production gate
without an explicit decision.

### `owner-statements`

Source routine: `capture-knowledge-to-brain`.

Purpose: Capture durable owner-stated knowledge from recent conversations.

Candidate signals:

- Product or architecture decisions and their rationale.
- Definitions, mental models, invariants, boundaries, preferences, and standing
  work rules.
- Clarifications that correct a wrong assumption a future agent might repeat.

Output in `apply`: brain concept/preference/sop/reference records. Search for
an existing record first and update it in place; do not create duplicate records.
Never store secrets. Do not create `decision` records; append decision material
to the existing decisions log when the project's brain contract requires it.

Skip: ephemeral task state, unverified hunches, scratch commands, and anything
already captured in brain, docs, code, or git history.

### `friction-patterns`

Source routine: `daily-self-improvement-loop`.

Purpose: Improve the agent tooling layer from repeated session friction.

Candidate signals:

- Recurring multi-step manual workflows that should become a skill.
- Cadenced manual chores that should become or extend a routine.
- Repeated safe read-only permission prompts that should be allowlisted.
- Repeated stale-doc corrections or standing behavior requests.
- Existing skills or routines repeatedly worked around or misunderstood.

Output in `apply`: targeted, low-blast-radius tooling changes only: new or
edited skills/routines, safe read-only permission allowlist additions, or
CLAUDE/AGENTS/memory clarifications where the project allows them. Also file an
audit kanban card for each applied change, or a product-code card when the
finding belongs outside the tooling layer.

Limits: at most two new skills and one new scheduled routine per run unless the
profile override says otherwise. Never deploy, never touch production, and never
delete or wholesale rewrite existing tooling.

## Apply Mechanics

For kanban cards, follow the shared contract exactly: clean `Repo:`,
`Base: main`, `Branch: kanban/<slug>`, a north star or `## END STATE`, then
GOAL / CONTEXT / STEPS / VERIFY / DONE WHEN. Use repo venue/config records to
choose GitHub vs Forgejo only for dedupe; mining routines do not open PRs.

For brain records, use typed reads/searches first. Upsert small records through
the normal brain path; for larger multiline bodies, stage a body file and pass
it to the CLI or MCP tool instead of forcing large inline JSON.

For direct tooling edits in `friction-patterns`, keep changes additive and
reversible, re-read every edited file after writing it, and file the audit card
before reporting success.

## Report

Always end with:

- Profile, window, mode, transcript directory, transcript count, and genuine
  session count.
- Candidate clusters with recurrence and evidence.
- Writes performed, or in `report-only`, writes that would be performed.
- Skips with reasons: already-known, already-fixed, one-off, not actionable, or
  human-gated.
- For the EdgeVector reference set, note which thin scheduled trigger can call
  this profile:
  `daily-agent-papercut-sweep -> papercuts`,
  `daily-retro-prevention -> incidents`,
  `capture-knowledge-to-brain -> owner-statements`,
  `daily-self-improvement-loop -> friction-patterns`.
