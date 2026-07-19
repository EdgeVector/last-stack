---
name: registry-rotator
description: |
  Generic scheduled-routine engine for registry-backed rotations. Given a
  registry record slug, pick the eligible entry with the largest overdue ratio
  (age divided by cadence), run its recipe, file cards per the shared routine
  contract, stamp only the registry rotation-log block, and heartbeat. Supports
  dry-run mode for selection and stamp-diff verification.
---

# Registry Rotator

Use this skill when a scheduled routine says to rotate one named registry, for
example `registry=dogfood-registry`, `registry=teardown-registry`,
`registry=canonicalization-registry`, or `registry=ownership-map`. This is an
engine: it walks a project-provided registry record and files work. It does not
ship code, open worktrees, open PRs, or spawn agents.

## Inputs

Required:

- `registry=<slug>`: the brain record holding the registry.

Optional:

- `type=<type>`: brain type for the registry. Default: `project`.
- `mode=dry-run|run`: default `run`. Dry run computes the selected entry and
  prints the rotation-log diff it would write, but makes no brain, board, repo,
  or external-service mutations.
- `routine=<name>`: heartbeat name. Default: `registry-rotator:<registry>`.
- `config-source=<slug-or-app-ref>`: where project config lives. If omitted,
  read the live project config from F-Config when available, otherwise use the
  interim brain shims named below.

If `registry` is missing, stop and report the missing argument.

## Run Start

1. Source the Last Stack shell prelude if available and run the CLI preflight for
   `git`, `curl`, `jq`, `kanban`, and `brain`.
2. Fetch `sop-routine-shared-contract` and honor it. If this skill conflicts
   with that SOP, the SOP wins.
3. Load project configuration from the declared config source. Until F-Config is
   present, read these brain shim records:
   `workspace-config`, `repo-venue-map`, and any registry-specific mapping record
   named by the entry. Use these records for workspace roots, checkout paths,
   worktree roots, repo venues, merge mechanisms, CI gate names, and hands-off
   flags.
4. Never embed EdgeVector-specific paths, repo lists, venues, sockets, cards, or
   owner names in this engine. If required config is absent, do not guess; report
   the missing config, heartbeat `error`, and stop.

## Registry Shape

A registry is a Markdown brain record with:

- One entry per rotatable unit, normally headed as `### <entry-slug> ...`.
- Entry fields for `track`, `cadence`, `recipe`, `pass =`, and `isolation`.
- Optional eligibility fields such as `eligible: false`,
  `auto-rotation: false`, `retired`, `planned`, `manual`, or project-specific
  skip markers defined in the registry prose.
- One owned block:

```markdown
<!-- rotation-log:start | auto-maintained by <routine> -->
| feature | last_run | result | cards filed |
|---|---|---|---|
| entry-slug | 2026-07-12 | pass | -- |
<!-- rotation-log:end -->
```

Treat the block names `rotation-log:start` and `rotation-log:end` as the write
boundary. Preserve all bytes outside that block. If the block is missing,
malformed, or has no row for the selected entry, file or report a registry-fix
card instead of rewriting the whole record.

## Select One Entry

Read the full registry body before selecting. Build the candidate set from
entries that have a cadence and a recipe or inline steps.

Eligibility rules:

- Honor explicit registry filters before scoring.
- Skip entries whose heading or fields say retired, planned, manual,
  rig-required, disabled, desktop-off, ineligible, `eligible: false`, or
  `auto-rotation: false`.
- Skip entries under manual/rig-required sections unless that section explicitly
  re-enables auto rotation.
- Skip entries whose isolation rule cannot be honored autonomously.
- If a registry defines additional eligibility filters, use those filters.

Scoring:

- Parse cadence values such as `2h`, `6h`, `24h`, `48h`, `1d`, `2 days`,
  `weekly`, or `7d` into hours.
- Read `last_run` from the rotation-log row for that entry.
- `--`, `-`, `never`, and `— never` count as never run and score as positive
  infinity.
- Otherwise compute `age = now - last_run` and `overdue = age / cadence`.
- An entry is due only when `overdue >= 1`.
- Pick the due entry with the largest overdue ratio. Ties go to the first entry
  in registry order.
- If no entry is due, report the next-up entry and when it becomes due, heartbeat
  `noop`, and stop.

Dry-run mode stops after selection and stamp planning. Print:

- selected entry and overdue ratio;
- reason any close contenders were skipped, when relevant;
- the recipe form that would dispatch;
- a unified diff of only the rotation-log block row that would change, using
  result `dry-run` and cards filed `--`.

Dry run must not write brain, kanban, files, repos, tickets, or external apps.

## Run The Recipe

Dispatch exactly one selected entry.

Recipe forms, in order of preference:

- **Skill name**: invoke the named skill with the entry context. Read that
  skill's instructions if the harness requires it. The invoked skill must honor
  this entry's isolation and pass assertion.
- **Command plus assertion**: run the command in the project-configured checkout
  or scratch location. Evaluate the `pass =` assertion against real output,
  artifacts, exit codes, and logs named by the entry. Exit 0 alone is not a pass
  unless the assertion says so.
- **Inline steps**: follow the entry's steps exactly, using the configured
  workspace/repo information and the entry's isolation rule.

Isolation is mandatory. Run recipes only on ephemeral/dev/scratch resources
declared by the entry and project config. Never use the primary brain, primary
keyring, production services, live user data, or human-only devices unless the
registry explicitly says the entry is a human/manual rig, in which case this
engine skips it.

Classify the result as:

- `pass`: the pass assertion is proven.
- `fail`: the recipe ran and the product behavior failed the assertion.
- `blocked`: an external or prerequisite condition prevents an honest run.
- `recipe-broken`: the recipe cannot reach or evaluate its own assertion.

## File Findings

Papercuts (friction, confusing UX, tooling misbehavior) go to BRAIN ONLY —
slug `papercut-<short-topic>`, search-first + update-in-place, per
`preference-always-file-papercuts-in-brain` (Tom 2026-07-19: no direct
kanban papercut cards; a triage routine promotes them). For each failed
assertion, missing fixture, stale recipe, or genuine BLOCKER (a feature or
recipe that cannot run) that should survive this run, file one kanban card
per `sop-routine-shared-contract` section 3.

Before filing, dedupe per the shared contract:

- live board cards;
- open review artifacts at the repo venue from project config;
- active worktrees;
- recently merged PRs or closed review artifacts relevant to the area;
- any registry-specific ledger named by the entry.

Cards must be pickup-ready when the fix is clear. Put uncertain or oversized
work in `backlog` with a narrow investigation goal. Do not run `kanban-agent`
from this skill.

Resolve the card's `Repo:` and PR venue from project config. If the entry names
an area/tag but not a repo, use the project-configured mapping record. If no
mapping exists, file a registry/config fix card instead of guessing.

## Stamp The Rotation Log

After recipe dispatch and card filing, re-read the full registry body. Replace
only the selected entry's table row inside the `rotation-log:start/end` block:

- `last_run`: current UTC date as `YYYY-MM-DD`;
- `result`: one of `pass`, `fail`, `blocked`, or `recipe-broken`;
- `cards filed`: comma-separated card slugs, or `--` when none were filed.

Preserve every other row and all prose. Write back with `brain put` using the
same slug and type. Do not use append for the registry. If the record changed
under you and the selected row can no longer be matched safely, stop, heartbeat
`error`, and report the concurrent edit.

## Heartbeat And Report

Heartbeat last, even after no-op or error, using
`last-stack-brain-append-heartbeat` when available. Format:

`<routine-name> <ISO-UTC> <ok|noop|error> <one-line outcome>`

Use `noop` only when nothing was due or a dry run intentionally made no changes.
Use `ok` when a real run completed and stamped the registry. Use `error` for
missing config, unreachable brain/board for the whole run, malformed registry,
or a failed write.

The final report should name the registry, selected entry, overdue ratio,
result, cards filed, rotation-log stamp, and next-up entry.
