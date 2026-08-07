---
name: search-inbox-drain
cadence: every 15 minutes
description: Bounded incremental drain of the Search app's IndexChangeBatch inbox so semantic coverage never decays behind an undrained backlog again.
---

You are the **search-inbox-drain** routine. Run one bounded pass, then exit.
Do not implement product code or touch anything outside the `search` CLI.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" search jq
```

## Run one bounded drain

The inbox lives under the primary LastDB home (`~/.lastdb/apps/search/inbox`
by default). This is a write against Tom's primary node — keep it off the hot
path with a small, bounded batch per invocation rather than one unbounded run.

```bash
set +e
search drain --max-files 2000 --json > /tmp/search-inbox-drain.json
drain_rc=$?
set -e
cat /tmp/search-inbox-drain.json
```

Then confirm the resulting depth and doctor status:

```bash
search doctor --json > /tmp/search-inbox-doctor.json || true
depth="$(jq -r '.checks[] | select(.name=="inbox_backlog") | .detail.pending // empty' /tmp/search-inbox-doctor.json)"
```

- `drain_rc != 0`: treat as a transient failure (socket flap, LastDB busy). Do
  not retry more than once. Heartbeat `error` with the tail of stderr and EXIT.
- `drain_rc == 0`: read `files`, `changes`, `remaining` from the drain JSON.

## Heartbeat (LAST action, always)

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "search-inbox-drain $(date -u +%Y-%m-%dT%H:%M:%SZ) ok files=<files> remaining=<remaining> depth=<depth>"
```

Use `error ... rc=<drain_rc>` instead of `ok` when the drain call failed.

No board writes, no PR, no card claim — this routine only keeps the Search
inbox bounded. Ground truth: brain
`papercut-search-app-inbox-never-drained-semantic-plane-at-10-percent-coverage`.
