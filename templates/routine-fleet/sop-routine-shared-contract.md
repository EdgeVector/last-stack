---
type: sop
slug: sop-routine-shared-contract
title: SOP - Shared routine contract
status: active
tags: routines, portability, driving-layer, canonical, sop
---
# SOP - Shared Routine Contract

Every scheduled routine cites this record instead of copying these rules into
its prompt. Fetch it at run start:

```bash
<BRAIN_CLI> get sop-routine-shared-contract
```

If a routine prompt conflicts with this SOP, this SOP wins unless the prompt
explicitly records a newer project decision.

## 1. Heartbeat

Append one line at the end of every scheduled run, including no-op and error
runs.

<!-- Brain record that stores routine health. -->
- **heartbeat_record**: `<ROUTINE_HEARTBEATS_SLUG>`

<!-- Exact line format routines must write. -->
- **line_format**: `<ROUTINE_NAME> <ISO_UTC_TS> <ok|noop|error> <ONE_LINE_OUTCOME>`

<!-- Preferred helper. Use "none" if the project has not built one yet. -->
- **append_helper**: `<HEARTBEAT_APPEND_HELPER_OR_NONE>`

## 2. Primary-data guardrail

- Never restart, reset, kill, or migrate `<PRIMARY_BRAIN_GUARDRAIL>` without the
  owner named in `workspace-config`.
- Treat timeouts and "too many concurrent reads" as load/backpressure, not proof
  that the node is dead.
- Use targeted reads for health checks. Do not use control-plane doctor/init
  commands as routine liveness checks unless the project explicitly marks them
  safe.

## 3. File work, do not ship from generator routines

Generator and triage routines file cards. The pickup/agent pipeline ships the
work. A pickup-ready card body must include:

1. The project-standard agent trigger line.
2. `Repo: <OWNER>/<REPO>`, `Base: <BASE_BRANCH>`, and `Branch: kanban/<SLUG>`.
3. A North Star or explicit END STATE.
4. `GOAL`, `CONTEXT`, `STEPS`, `VERIFY`, and `DONE WHEN`.

Too large or ambiguous means file backlog work, not product changes.

## 4. Dedupe before filing

Check all configured dedupe surfaces before creating a card:

- live board across columns;
- open PRs or CRs at the repo venue;
- active worktrees and local branches;
- recently merged PRs for the same area;
- source-specific ledgers from `signal-sources` or probe verdicts.

When in doubt, update an existing card or report ambiguity instead of filing a
near-duplicate.

## 5. File papercuts — every agent, every run, and the default is FILE

A papercut is any friction you hit while doing the real work: a tool that
misbehaves, a check that reports about something it cannot observe, a confusing
or truncated error, a stale convention, a manual workaround, a doc or comment
that contradicts what executes, a recipe that no longer runs. Filing them is how
the system improves; nothing else in this contract collects that signal.

<!-- The project's papercut ledger. Use "none" if the project has not built one. -->
- **papercut_ledger**: `<PAPERCUT_LEDGER_CLI_OR_NONE>`

<!-- The single routine allowed to turn papercuts into board cards. -->
- **papercut_reconciler**: `<PAPERCUT_RECONCILER_ROUTINE_OR_NONE>`

Rules, in the order they are usually broken:

1. **The default is FILE, not judge.** You do not have to decide a finding is
   important, novel, or big enough. The gate is only *"is this a distinct claim
   someone would want to find?"* A run that files nothing needs an explicit
   reason, and "it was small", "it is probably already known", and "that one was
   my own mistake" are not reasons.
2. **Papercuts go to the brain, never straight to the board.** Only
   `<PAPERCUT_RECONCILER_ROUTINE_OR_NONE>` promotes them to cards, so it can
   dedupe and cluster them. Filing a card yourself produces board noise and
   hides the pattern.
3. **Search before you file, and read what you find as a REMEDY, not just as
   precedent.** An existing record may already prescribe the fix, may list the
   systems checked for exposure, or may be the right place for your evidence.
   Appending measured evidence to an open record beats filing its near-duplicate.
4. **A mention is not a filing.** Prose in a checkpoint, a commit message, a PR
   description, a run summary, or a closure block reaches no triage routine and
   produces no card. If it is not a record with its own slug, it was not filed.
5. **Burying a finding inside a record you then CLOSE is worse than not filing
   it.** An unfiled finding is absent, and absence is honest — someone
   rediscovers it. A finding written as an aside inside a closed record is
   *present*: it reads as recorded and is invisible to every open-backlog
   reader, every count of open work, and every stale-record sweep. **Before
   closing any record, ask whether its body contains a claim about something
   OTHER than the thing being closed. If it does, that part needs its own slug
   before the close lands.**
6. **File it in the moment.** Friction that stays in one agent's context helps
   once; a record compounds. Cheap same-session fixes are still encouraged —
   file it, fix it, then close it with the evidence.

A filed papercut carries enough for the reconciler to card it without you:
symptom, the exact failing output, how to reproduce, the date measured, the
affected repo, and a suggested fix if you have one.

## 6. Scheduled-run shell discipline

- Normalize PATH before CLI preflight: `<PATH_PREFIX>`.
- Run one bounded pass, then exit.
- Do not loop forever and do not sleep-poll.
- Use foreground watchers only when the routine's job is to drive a review
  artifact to a terminal state.
- Keep Markdown, card bodies, and brain records as data; never paste them into a
  shell for execution.
- Use body files or stdin for long text writes.

## 7. Verify against default branch

Before calling something broken, missing, or stale, fetch the target repo and
verify against `origin/<BASE_BRANCH>`. Do not make factual reports from a stale
checkout.

## 8. Delimited block ownership

For records with managed blocks such as `<!-- owner:start -->` and
`<!-- owner:end -->`, only the owning routine edits its block. Read the full
record before replacing a block and preserve unrelated content byte-for-byte.

## 9. Ground-truth verdicts

Continuous probes write verdict records with newest-on-top lines:

```text
<ISO_UTC_TS> <GREEN|RED> <KEY_METRICS> run=<RUN_ID> <EVIDENCE_POINTER>
```

Only a full passing run is green. Skipped, partial, blocked, or harness-broken
runs are not green.

## 10. Human gates

Use the project's authoritative decision ledger, not derived summaries, to
decide whether a human gate is still open.

<!-- Brain record or board source for human-only decisions. -->
- **decision_ledger**: `<OPEN_DECISIONS_SLUG_OR_EQUIVALENT>`

## Validation

- A routine can cite this SOP plus the Layer-2 records and run without copying
  project constants into its prompt.
- Updating a project path, venue, or token locator requires editing config only,
  not engine skills or routine prompts.
