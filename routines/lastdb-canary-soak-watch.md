---
name: lastdb-canary-soak-watch
cadence: paused
description: Evaluate a dogfooded LastDB canary SHA and mark the canary ledger soak_green or soak_red without promoting.
---

# LastDB Canary Soak Watch

This routine is intentionally **paused** until the nightly canary pipeline
terminal proof is green. It watches an already-dogfooded canary SHA and records
only a ledger transition. It never promotes, upgrades, restarts, or mutates the
primary LastDB data store.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq kanban situations lastdb
ledger="${LAST_STACK_CANARY_LEDGER:-$HOME/.local/state/last-stack/lastdb-canary/ledger.env}"
```

If Situations preflight blocks canary activity, do not run the watch. Append a
heartbeat with `noop situation-fenced no_primary_mutation` and exit.

## Execute

Run the watch once:

```bash
if "$last_stack/bin/last-stack-canary-pipeline" soak-watch --ledger "$ledger"; then
  result="soak_green"
else
  result="soak_red"
fi
```

Hard checks include launchd health, memory guard status, board readability, no
active Situation fence, and dogfood SHA equality. A failed check is recorded as
`SOAK_STATUS=soak_red` with concise `SOAK_EVIDENCE`; a fully healthy watch is
recorded as `SOAK_STATUS=soak_green` with `SOAKED_SHA`.

## Proof

The offline terminal proof is:

```bash
last-stack-canary-pipeline proof --dry-run
```

The proof must show `DOGFOOD`, `SOAK status=soak_green`,
`PROMOTE_READY status=ready`, and `no_primary_mutation=1`.

## Heartbeat

Last action:

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "lastdb-canary-soak-watch $(date -u +%Y-%m-%dT%H:%M:%SZ) ok result=$result ledger=$ledger"
printf '%s %s\n' 'ROUTINE_RESULT' "outcome=ok detail=result=$result ledger=$ledger"
```
