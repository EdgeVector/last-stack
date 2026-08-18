---
name: brain-sync
cadence: hourly
description: Compatibility coordinator for the brain sync schedule. Delegates to the current rollup/consolidation routines instead of carrying a second copy of their logic.
---

You are the **brain-sync** compatibility routine. Run one bounded pass, then
exit.

This prompt exists so older live registry entries that still point at
`routines/brain-sync.md` resolve cleanly. Do not add a new implementation here.
The source-of-truth prompts are:

- `program-rollup` for `active-programs` board status mirrors
- `north-star-rollup` for the North Star dashboard
- `consolidate-brain` for daily status/prose consolidation
- `north-star-hygiene` for missing North Star project materialization

## Safety

- Never edit source code, open PRs, move board cards, or restart shared nodes.
- Treat LastDB/board backpressure as a `noop` skip; do not run doctor/init or
  restart services.
- If you hit a rate limit, stop immediately with a `noop` result.
- Read and write only the exact automation memory path injected in the dispatch
  envelope. If no path was injected, use the standard routines memory path for
  this automation id.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq brain kanban
```

## Run

1. Run a socket-safe health read:
   ```bash
   kanban list --column todo --json >/tmp/last-stack-brain-sync-board.json
   ```
   If this reports `service_timeout`, `node did not respond`, `too many
   concurrent reads`, or socket backpressure, heartbeat `noop busy-node
   skipped-brain-sync` and exit.
2. Read the current prompt text through `last-stack-routine-read` for
   `program-rollup`, `north-star-rollup`, and `consolidate-brain`. This proves
   the installed prompt set is complete without duplicating those prompts in
   this run.
3. Do not execute sub-routines from inside this compatibility prompt. The
   scheduler owns their cadence and isolation. Report `noop compatibility-shim
   delegated-to-current-routines`.

## Heartbeat

As the final action, append:

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "brain-sync <ISO-ts> noop compatibility-shim delegated-to-current-routines"
```

Then print the machine trailer using the `ROUTINE_RESULT` token followed by
`outcome=<noop> detail=compatibility-shim delegated-to-current-routines`.

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
