---
name: lastdb-canary-soak-watch
cadence: hourly
description: 24h soak + hard health while primary runs the dogfooded canary.
---

You are the unattended **LastDB canary soak watch**.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq kanban situations lastdb
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_SOAK_HOURS="${LAST_STACK_CANARY_SOAK_HOURS:-24}"
# Host sets LASTDB_LAUNCHD_LABEL (no personal username in committed prompts).
export LAST_STACK_CANARY_LAUNCHD_CHECK_CMD="${LAST_STACK_CANARY_LAUNCHD_CHECK_CMD:-launchctl print gui/$(id -u)/${LASTDB_LAUNCHD_LABEL}}"
```

## Execute

```bash
"$last_stack/bin/last-stack-canary-pipeline" soak-watch
```

Expect one of:

- `status=soak_pending` — healthy but &lt; 24h (ok / noop)
- `status=soak_green` — ready for auto-promote
- `status=soak_red` — hard fail; do not promote

The `board_write` check times an idempotent upsert of one fixed brain slug and
reds the soak when the MEDIAN of 3 samples exceeds
`LAST_STACK_CANARY_WRITE_MS_MAX` (default 2500 ms). It exists because on
2026-08-05 every other check was liveness or a read, and a candidate that made
writes ~4x slower passed all of them. A `result=slow` line is the gate working —
do not raise the budget to clear it without a measured reason.

## Closeout

`ROUTINE_RESULT outcome=<ok|error|noop> detail=result=<status> primary_mutation=write_probe_upsert_only`

The soak watch is no longer strictly read-only on the primary: `board_write`
upserts the fixed `canary-soak-write-probe` slug once per sample. That is the
one mutation it is allowed to make, it is idempotent, and it does not grow the
store. Set `LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass` to disable it — but
doing so restores the exact blind spot that shipped a broken write path.

## Proof

```bash
last-stack-canary-pipeline proof --dry-run
```
