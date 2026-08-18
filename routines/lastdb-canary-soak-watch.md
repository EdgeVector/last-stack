---
name: lastdb-canary-soak-watch
cadence: hourly
description: Tick the lastdb-canary-release state machine — advances the soak clock and the hard health checks.
---

You are the unattended **LastDB canary soak watch**. You are the clock for the
`lastdb-canary-release` state machine: its `SOAK_WAIT` state is a 1h timer, and
nothing advances a durable machine except a tick.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq kanban situations lastdb sm
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_SOAK_HOURS="${LAST_STACK_CANARY_SOAK_HOURS:-24}"
# Host sets LASTDB_LAUNCHD_LABEL (no personal username in committed prompts).
export LAST_STACK_CANARY_LAUNCHD_CHECK_CMD="${LAST_STACK_CANARY_LAUNCHD_CHECK_CMD:-launchctl print gui/$(id -u)/${LASTDB_LAUNCHD_LABEL}}"
```

## Execute

```bash
sm tick --definition lastdb-canary-release --cap 4 --json
sm list --definition lastdb-canary-release --json
```

If no execution is running, the tick is a no-op and this routine is `noop`.
**An idle lane is not an error.** Do not "fix" a quiet night by starting an
execution here — that is the nightly routine's job, and starting one out of
band is how a cutover happens at an hour nobody expects.

## What the SOAK state checks

`SOAK` runs `last-stack-canary-pipeline soak-watch`, whose hard checks are
`launchd`, `memory_guard` (RSS against the same ceiling safe-upgrade uses),
`board_read`, `board_write`, and a **scoped** `situations preflight --action
lastdb-safe-upgrade`.

Two of those are load-bearing in a way that invites tampering:

- `board_write` times an idempotent upsert of one fixed brain slug and reds the
  soak when the MEDIAN of 3 samples exceeds `LAST_STACK_CANARY_WRITE_MS_MAX`
  (default 2500 ms). It exists because on 2026-08-05 every other check was
  liveness or a read, and a candidate that made writes ~4x slower passed all of
  them. A `result=slow` line is the gate working — do not raise the budget to
  clear it without a measured reason.
- The situation fence asks preflight for **one action**. It used to test
  `situations list | jq length == 0`, so an unrelated codex harness outage
  red'd every soak for three weeks. Do not "simplify" it back.

Expect one of: `status=soak_pending` (healthy, under the window — `ok`/`noop`),
`status=soak_green` (machine advances to PROMOTE), `status=soak_red` (hard fail;
terminal for that candidate — the next night's build supersedes it), or
`status=no_active_candidate` (nothing soaking — `noop`, exit 0).

## Closeout

`ROUTINE_RESULT outcome=<ok|error|noop> detail=exec=… state=… result=<status> primary_mutation=write_probe_upsert_only`

The soak is not strictly read-only on the primary: `board_write` upserts the
fixed `canary-soak-write-probe` slug once per sample. That is the one mutation
it may make, it is idempotent, and it does not grow the store. Setting
`LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass` disables it — and restores the
exact blind spot that shipped a broken write path.

## Proof

```bash
last-stack-canary-pipeline proof --dry-run
```

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
