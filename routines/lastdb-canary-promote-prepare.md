---
name: lastdb-canary-promote-prepare
cadence: every 6 hours
description: Prepare and notify a LastDB canary promotion. Never publish stable.
---

You prepare a LastDB canary promotion. You never publish it.

The canary v2 migration that held this routine finished on 2026-09-05. The
North Star `north-star-lastdb-canary-pipeline-v2` is done and its terminal
proof reads PASS, including the CHANNELS stage. So the v1 hold text is retired
and this routine does real work again.

The hold that remains is narrower and permanent: **stable publication is an
explicit human action.** This routine writes the promotion material and
notifies. It never runs `promote-execute`. It never pushes a brew bottle, a
stable tag, or an artifact promotion. It never restarts or mutates the primary
LastDB node. A live primary version change stays with the `lastdb-safe-upgrade`
skill and its human gate.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq situations
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

Read the active Situations first. If a Situation blocks a canary or LastDB
action, record the slug and do no mutation this run.

## Execute

Run the prepare step. It reads the canary ledger, writes promotion material
when a candidate is `soak_green`, and sends one notification.

```bash
set +e
"$last_stack/bin/last-stack-canary-pipeline" promote-prepare
prepare_rc=$?
set -e
```

Read the single `PROMOTE_READY` line it prints. The `status=` field carries the
result:

- `ready` — a candidate reached `soak_green`. The command wrote a `PROMOTE.md`
  under the promote root and notified. The `output=` field names that file.
  This run is `ok`.
- `no_active_candidate` — nothing is awaiting promotion. This run is `noop`.
- `blocked` — the newest candidate is in a state that cannot promote. The
  command exits 1 for this case. It is a normal lane state, not a routine
  fault, so report it as `noop` with the `soak_status=` value. Do not report
  `error` and do not retry.

A missing ledger, a crash, or any output without a `PROMOTE_READY` line is a
real `error`.

## Hard bans

- Do not run `promote-execute`.
- Do not run `brew`, `host-track promote`, or any stable-channel publish.
- Do not restart, kill, or upgrade the primary LastDB node.
- Do not raise the candidate's ledger state by hand.

## Closeout

Print the `PROMOTE_READY` line. Then run the close-out skill. Write the outcome
sink at `$ROUTINES_RUN_DIR/outcome.txt` with one verdict line: `ok` when a
candidate is ready, `noop` when the lane has nothing to prepare or is blocked,
`error` for a real fault. End with the heartbeat and one final line that starts
with the `ROUTINE_RESULT` token, followed by the outcome and a short detail.
