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
