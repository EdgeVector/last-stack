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
"$last_stack/bin/last-stack-card-reaper-run"
```

After the command exits, make your final response exactly the final
`card-reaper ...` heartbeat line printed by the command, and nothing else.
