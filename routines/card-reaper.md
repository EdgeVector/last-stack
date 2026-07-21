---
name: card-reaper
cadence: hourly
description: Enforce card-staleness SLAs on the kanban board with the deterministic last-stack card reaper runner.
---

You are the **card-reaper** routine for the EdgeVector workspace
(`/Users/tomtang/code/edgevector`). Run one bounded pass with the installed
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
