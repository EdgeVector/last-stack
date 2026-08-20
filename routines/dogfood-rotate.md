---
name: dogfood-rotate
cadence: daily
description: Thin trigger over dogfood-registry. A start-contract gate selects one runnable entry; recipes that cannot start are skipped, never compiled.
---

You are the **dogfood-rotate** routine. Each run starts cold. Run the
**start-contract gate first**. Do not improvise a Fold build. Do not `cargo
build`. Files work only; never ships fixes.

This is a thin trigger over the **registry-rotator** engine plus
`last-stack-dogfood-rotate-gate`. Project recipes live in Brain
`dogfood-registry`, not in this prompt.

**Shared contract:** fetch `brain get sop-routine-shared-contract --type sop`
at run start and honor it — heartbeat LAST always, primary-brain guardrail,
FILE-don't-ship, dedupe-before-filing, scheduled-run shell discipline. If this
prompt conflicts with it, the contract wins.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq brain kanban
```

Prefer reading this routine through `last-stack-routine-read dogfood-rotate`
(it auto-upgrades a stale clean install). Honor
`[[preference-agents-work-in-worktrees-install-checkout-disposable]]`. If
self-upgrade, routine-read, or host-track is blocked by tracked dirt in the
install checkout, authorized remediation is to create a backup branch, then
run `git reset --hard lastgit/main` in the install checkout and retry. Do not
ask Tom and do not file an install-dir blocker for dirt alone. If the
dirty-install path still returns `error-dirty` / `warn: last-stack-checkout-dirty`
and cannot be repaired in this bounded run, emit a noop heartbeat with
`reason=last-stack-checkout-dirty` and stop; this is not a dogfood error. If
routine-read emits `LAST_STACK_ROUTINE_DEFERRED self_upgrade_lock`, STOP,
heartbeat a bounded noop with `reason=self-upgrade-lock`, and do not file an install-dir blocker;
the concurrent self-upgrade or next scheduled run owns
recovery. If routine-read emits `LAST_STACK_ROUTINE_DEFERRED self_upgrade_fetch_failed`,
STOP, heartbeat a bounded noop with `reason=self-upgrade-fetch-failed`, and
let the next scheduled run retry.

Default board is `default`. Only `list` / `add` take `--board`; `show` /
`move` / `rm` reject it.

Health check is socket-backed `brain get dogfood-registry --type project` then
`kanban list --column todo --json`. Do not use `brain doctor`, `kanban doctor`,
or TCP `:9001`. Busy-node (`service_timeout` / too many concurrent reads) →
STOP, heartbeat `noop busy-node`.

## Gate first (won't-undo)

Run, in one foreground Bash call:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-dogfood-rotate-gate"
```

The gate reads `dogfood-registry` and **skips** every entry that cannot start:

- **Retired / ineligible auto-rotation surfaces** (`status: retired`,
  `eligible: false`, `auto-rotation: false`)
- `requires: compile` or a `command` containing `cargo build`
- `requires: staged-lastdbd` when `last-stack-canary-resolve-lastdbd` returns
  `need_build`
- secret-backed recipes that do not name a `credential-ref: lastsecrets://<slug>`
  and invoke the live consumer through `last-stack-secret-env-run`; do not run a credential-free subset
- entries that are not yet due (`last_run` younger than cadence)

If `RESULT … detail=no-runnable-entry`, heartbeat

`dogfood-rotate <ISO-ts> noop feature=- result=no-runnable-entry cards=0`

then close-out (heartbeat may serve as the report) and stop. That is success
of the gate, not an error.

If `SELECTED feature=<slug> … command=<cmd>`, run **exactly that command**
under the printed `timeout_sec` (or `last-stack-dogfood-rotate-gate --run`
when the command is a last-stack helper / self-contained script). Never
append `cargo build`. Never open a fold worktree to compile. If the command
contains `cargo`, treat it as gate failure, heartbeat `error
reason=selected-command-contains-cargo`, and stop.

## After the command

Classify from the gate / command output:

- `pass` — assertion held
- `fail` — recipe ran, product assertion failed → file one Kind:pr blocker
  with `$LAST_STACK_ROOT/bin/last-stack-kanban-file-pr` (live `--north-star`
  and `--milestone` from the registry entry's program). Dedup live cards
  first.
- `blocked` / `recipe-broken` — cannot honestly evaluate; file or reuse one
  recipe card, do not pretend the product failed

Papercuts (friction) go to Brain only: `brain papercut file` (search first,
update in place). Never a papercut kanban card.

Stamp only the `rotation-log` block in `dogfood-registry` (`pass` / `fail` /
`blocked` / `recipe-broken`, cards filed or `--`).

Heartbeat last via `last-stack-brain-append-heartbeat --line` with

`dogfood-rotate <ISO-ts> <ok|noop|error> feature=<slug> result=<result> cards=<n>`

## Guardrails

- Never `cargo build` / `cargo test` / `cargo bench` in this routine.
- Never touch `~/.lastdb` / the primary brain as a dogfood target.
- Files cards and Brain updates only. Do not ship product fixes.

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
