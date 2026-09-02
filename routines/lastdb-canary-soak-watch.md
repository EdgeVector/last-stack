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

The gate only plans actions by default. It runs an action only when both of
these settings are explicit:

```bash
LAST_STACK_CANARY_V2_EXECUTE_ACTIONS=1
LAST_STACK_CANARY_V2_ACTION_CMD='short-command'
```

The action command must finish quickly. It must not start a wait loop. Stable
channel promotion remains held until the channel proof is complete.

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line.
