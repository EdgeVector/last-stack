---
name: board-closeout
description: Drain stuck kanban doing cards — merged PRs/CRs to done, true zombies to todo — via the zero-LLM last-stack-board-closeout-sweep. Use when doing piles up, cards sit multi-hour after merge, low-credit paused watch, or Tom says board is stuck.
---

# Board closeout

## When to use

- Factory / board shows **doing** cards for many hours after work shipped
- `kanban-watch` is **paused** (common under `routines-profile apply low-credit`)
- Pickup heartbeats show `in-flight-budget-handoff` / `in-flight-ci-pending` and
  cards never reach `done`
- Soft 1h reclaim is **not** enough: it skips any card with a `pr_url`

## Do this (deterministic)

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
# Preview
"$last_stack/bin/last-stack-board-closeout-sweep" --dry-run
# Apply
"$last_stack/bin/last-stack-board-closeout-sweep"
# Ensure always-on (every 15m, zero API credits)
"$last_stack/bin/last-stack-board-closeout-install" install
"$last_stack/bin/last-stack-board-closeout-install" status
```

Heartbeat line shape:

```text
board-closeout <ISO> ok|noop closed=N closed_slugs=… rolled_back=N skipped=N flagged=…
```

## What it will not do

- Kill live agent processes
- Reclaim cards with an **open** PR/CR
- Open PRs for you — WIP-with-commits-but-no-`pr_url` after grace is rolled
  back to **`todo`** (flag `wip-no-pr:<slug>`; worktree kept) so pickup can
  resume. That state is a pickup contract violation (`handoff` requires a URL).

## Related

- Routine: `last-stack/routines/board-closeout.md`
- Soft 1h zombies: `preference-kanban-doing-soft-1h-reclaim`
- Always-on policy: `preference-kanban-board-closeout-always-on`
- Per-card helper: `last-stack-card-closeout <slug>`
