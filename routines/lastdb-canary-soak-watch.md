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

## Closeout

`ROUTINE_RESULT outcome=<ok|error|noop> detail=result=<status> no_primary_mutation=1`

## Proof

```bash
last-stack-canary-pipeline proof --dry-run
```
