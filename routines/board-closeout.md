---
name: board-closeout
cadence: every 15 min (LaunchAgent) / optional LLM routine
description: Deterministic zero-LLM closeout — merged PR/CR cards → done; true zombie doing claims → todo. Survives low-credit when kanban-watch is paused.
---

You are the **board-closeout** backstop for `<WORKSPACE>`. Prefer the
**LaunchAgent** / deterministic runner over an LLM pass — this routine exists so
scheduled fleets and agents have a documented owner for the gap below.

## Why this exists

`kanban-pickup` intentionally leaves cards in `doing` after
`in-flight-budget-handoff` / `in-flight-ci-pending` once a PR/CR exists.
**Only** a reconciler moves those cards to `done` when the PR merges.

When `kanban-watch` is paused (e.g. **low-credit** ship-only profile), merge
routines can still merge PRs while the board claim sits for hours. Soft 1h
zombie reclaim **skips** cards with `pr_url`, so age alone never cleans them.

This closeout is the always-on, zero-credit answer:

| Condition | Action |
|-----------|--------|
| `doing` + PR/CR **merged** | `last-stack-card-closeout` → `done` only if any `Requires-Deploy:` gate has terminal success |
| `doing`, age ≥ 60m, no PR, no live worker, no branch commits | `move todo` |
| `doing`, age ≥ 60m, no PR, no live worker, **WIP commits** (illegal handoff) | `move todo` (flag `wip-no-pr`; worktree kept) |
| open PR / live worker / younger than grace | skip |

Durable: brain `preference-kanban-board-closeout-always-on` and
`preference-kanban-doing-soft-1h-reclaim`.

`Requires-Deploy: deploy-pipeline` is a machine gate, not prose. The closeout
helper reads `last-stack-pipeline-deploy-scan --json`; pending, missing, or red
deploy status leaves the card out of `done` even when the PR/CR is merged.

## Preferred: LaunchAgent (no LLM)

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-board-closeout-install" install   # once
"$last_stack/bin/last-stack-board-closeout-install" status
"$last_stack/bin/last-stack-board-closeout-sweep"             # run-once
"$last_stack/bin/last-stack-board-closeout-sweep" --dry-run
```

Cadence: every **15 minutes** via `com.edgevector.board-closeout`.

## If this routine is scheduled on an LLM harness

Run **only** the deterministic binary, then exit with its heartbeat line:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" kanban
"$last_stack/bin/last-stack-board-closeout-sweep"
```

Final response = the printed `board-closeout <ISO> …` line. Do not invent
card moves, do not open PRs, do not restart `lastdbd`.

## Called from other routines (belt + suspenders)

These should invoke the sweep as a **CHEAP first or last step** even when the
LaunchAgent is healthy:

- `kanban-watch` — before zombie reclaim / PR reconcile
- `kanban-pickup` — before claiming new work
- `pipeline-health` / `merge-babysit` — after unsticking merges
- `card-reaper` — before pr_url skip logic

## Guardrails

- Never SIGKILL agents for age.
- Never move open-PR cards to `todo` just because they are old.
- Never force-merge. Only board column reconciliation after a verified merge.
- Busy-node / socket errors → heartbeat `noop flagged=busy-node`, exit 0.
