---
name: lastdb-canary-soak-watch
cadence: hourly
description: Reconcile LastDB canary v2 from durable boot and observation evidence.
---

You run the stateless LastDB canary v2 reconciler once each hour.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq curl situations
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Execute

Run the zero-agent gate first.

```bash
"$last_stack/bin/last-stack-canary-soak-watch-gate"
```

The gate reads the owner-only bounded boot ledger. It records a three-sample
status p95 with a 2-second budget. It records the host fence separately.

The gate then runs the deterministic verdict function against immutable rows.
It appends one reconciler row. It has no active marker, resume key, or wait
state. It does not run a Loom graph.

The result has one of these forms:

- `green`: The quiet window is complete. The candidate is eligible for the
  held promotion action.
- `red`: The build failed. A short configured heal action can run.
- `line-stopped`: The observer failed. A short configured line-stop action can
  run.
- `window-open`: The time window stays open. A host failure pauses the window.
- `superseded`: A newer build replaced the candidate.

Timeout, absence, and status p95 above 2 seconds are failures. A missing boot
row is build failure evidence.

## Action safety

The gate only plans actions by default. It starts one short action only when
`LAST_STACK_CANARY_V2_EXECUTE_ACTIONS=1` is set and the verdict maps to a
dispatchable action.

Allowed actions: build, heal, line-stop, pause, retire, promote.
`wait-next-check` is a fact for the next tick. The dispatcher never starts it.

Per-action commands:

```bash
LAST_STACK_CANARY_V2_BUILD_CMD='short-command'
LAST_STACK_CANARY_V2_HEAL_CMD='short-command'
LAST_STACK_CANARY_V2_LINE_STOP_CMD='short-command'
LAST_STACK_CANARY_V2_PAUSE_CMD='short-command'
LAST_STACK_CANARY_V2_RETIRE_CMD='short-command'
LAST_STACK_CANARY_V2_PROMOTE_CMD='short-command'
```

`LAST_STACK_CANARY_V2_ACTION_CMD` is a fallback override for tests. A missing
command leaves the action planned. It does not invent a wait loop.

`--dry-run` (or `LAST_STACK_CANARY_V2_DRY_RUN=1`) prints the action plan and
writes no reconciler evidence, primary state, or stable-channel state.

Stable channel promotion remains held until the channel proof is complete.

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line.
