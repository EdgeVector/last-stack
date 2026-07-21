---
name: self-upgrade
cadence: every 1–2 hours (or on any LAST_STACK_ROUTINE_STALE heartbeat)
description: Keep the installed Last Stack checkout (~/.last-stack) fast-forwarded to origin. Never develops in the install dir; may repair tracked install dirt with a backup branch plus reset.
---

You are the **self-upgrade** routine. Each run starts cold. Your only job is to
keep the **installed** Last Stack checkout current so other scheduled routines
do not die at the freshness gate.

## Why this exists
`last-stack-routine-read` fail-closes when the install is behind origin. Without
an automatic upgrade path, fleets stay stuck for days filing `stale-routine`
heartbeats and doing no real work. This routine (and the
`last-stack-self-upgrade` helper it calls) closes that loop for clean installs
and, per `[[preference-agents-work-in-worktrees-install-checkout-disposable]]`,
may repair tracked dirt in the disposable install checkout with a backup branch
plus reset.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-pickup`),
**not** the skill frontmatter `name:` (e.g. not bare `kanban-pickup`). Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly. If the
sandbox refuses the path, note `memory_unwritable=<path>` in the heartbeat and
continue — do not fail the whole run.

## Hard guardrails
- Do not develop, hand-edit skills, or intentionally leave uncommitted work in
  `${LAST_STACK_ROOT:-$HOME/.last-stack}`. Feature work belongs in a separate
  clone or isolated worktree via PR.
- If tracked dirt in `${LAST_STACK_ROOT:-$HOME/.last-stack}` blocks
  self-upgrade, routine-read, or host-track, the authorized repair is:
  create a backup branch, then `git reset --hard lastgit/main` in the install
  checkout. Do not ask Tom again and do not file install-dirty as
  `needs_human`.
- Do not `git clean -fd`, force-push, stash, merge, or delete worktrees from the
  install dir.
- NEVER set `LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1` or
  `LASTSTACK_SELF_UPGRADE_SKIP=1` to "make the pass succeed."
- Do ONE bounded pass, then exit.

## Procedure
1. Normalize the scheduled shell:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   "$last_stack/bin/last-stack-cli-preflight" git
   ```
2. Prefer the helper over open-coding git:
   ```bash
   "$last_stack/bin/last-stack-self-upgrade" --reason=self-upgrade-routine
   ```
   Interpret the machine line `LAST_STACK_SELF_UPGRADE result=...`:
   - `up-to-date` → noop (if `note=fetch-failed` only, remote was fully offline
     and we could not prove staleness — ok)
   - `upgraded` → success; note old→new heads
   - `error-fetch` → fetch failed while `ls-remote` still shows remote ahead.
     Heartbeat and STOP. Do not claim up-to-date. The launchd healer
     (`last-stack-self-upgrade-install`) will retry; after repeated fails,
     factory-health fires `install_stale_hard`.
   - `error-dirty` → repair tracked install dirt with backup-branch plus
     `git reset --hard lastgit/main`, then retry once. If the retry is still
     dirty, heartbeat the dirty sample and stop without filing a human blocker
     for dirt alone.
   - `error-diverged` / `error-pull` / `error-setup` / `error-lock` → STOP and
     heartbeat the result. Do not force.
3. Confirm the reader is healthy:
   ```bash
   "$last_stack/bin/last-stack-update-check"
   "$last_stack/bin/last-stack-routine-read" self-upgrade >/dev/null
   ```
   Both should succeed without `GIT_UPDATE_AVAILABLE` / `LAST_STACK_ROUTINE_STALE`.
4. Heartbeat (newest-on-top via the helper):
   ```bash
   ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   "$last_stack/bin/last-stack-brain-append-heartbeat" --line \
     "self-upgrade $ts <ok|noop|error> <result summary with heads>"
   ```
   If brain is busy (`service_timeout` / concurrent reads), write the same line
   into automation memory and exit; do not retry-loop.

## Install-dir policy (remember for every agent)
| Path | Role |
|---|---|
| `${LAST_STACK_ROOT:-$HOME/.last-stack}` | Installed product: clean, tracks origin |
| Separate workspace clone of last-stack | Development: branches, PRs, experiments |

## Report
One short paragraph: result (`up-to-date` / `upgraded` / dirty/diverged error),
local and remote heads if known, and whether `routine-read self-upgrade` is
healthy. Then exit.
