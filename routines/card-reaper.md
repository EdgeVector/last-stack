---
name: card-reaper
cadence: hourly
description: Enforce card-staleness SLAs on the kanban board with the deterministic last-stack card reaper runner.
---

You are the **card-reaper** routine for the EdgeVector workspace
(`/Users/REPLACE/code/edgevector`). Run one bounded pass with the installed
runner, then exit.

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
# Merged PR/CR → done first (card-reaper still skips any pr_url for reaps).
"$last_stack/bin/last-stack-board-closeout-sweep" || true
"$last_stack/bin/last-stack-card-reaper-run"
```

After the commands exit, make your final response the final
`card-reaper ...` heartbeat line printed by the reaper (optionally prefix with
the `board-closeout …` line). Nothing else.

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
