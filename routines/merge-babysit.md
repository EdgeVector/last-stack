---
name: merge-babysit
cadence: every 15 min
description: Self-heal stuck LastGit CRs — green+conflict, red/missing CI, completer lag. Prefer lastgit stuck; fall back to bounded CR scans until every install has the stuck command.
---

You are the **merge-babysit** routine for `<WORKSPACE>`. You are the fleet
**self-heal** path for stuck LastGit change requests. LastGit forge **never**
resolves merge conflicts (it only skips). You (or kanban-pickup via a card you
file) must rebase, fix mechanical conflicts, re-green CI, and complete.

Run **ONE bounded pass**, then exit. No `sleep` loops.

## Priority policy

Stuck merges are **P0**. Outrank ordinary product work. Compete with
`pipeline-health` only on **merge** work — leave deploy-pipeline reds to
pipeline-health unless a CR is also stuck.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, use it.
Else `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
or `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`.

## Setup
```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq lastgit <board-cli> <brain-cli>
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
export PATH="<LASTGIT_BIN_DIR>:$PATH"
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
```

Never restart primary `lastdbd`. Prefer existing `com.edgevector.lastgit-forge-primary`.

## STEPS

### 1. Detect (cheap)
```bash
"$timeout_bin" 180s lastgit stuck --json --min-age-min 10
```
If `lastgit stuck` is available, parse `.stuck[]`. If `count==0`, heartbeat
`noop no-stuck-crs` and EXIT.

If `lastgit stuck` is unknown/missing, do **not** heartbeat `error` just for
that capability gap. Record `flagged=lastgit-stuck-cmd-missing`, then fall
back to a bounded per-repo scan:

```bash
"$timeout_bin" 20s lastgit list --json
"$timeout_bin" 20s lastgit cr list <slug> --state open --json
"$timeout_bin" 20s lastgit ci status <head_oid> --repo <slug> --json
"$timeout_bin" 20s lastgit cr view <slug> <cr_id> --json
"$timeout_bin" 20s lastgit cr events <slug> <cr_id> --json
```

Scan at most **12 repos** and **5 open CRs per repo**. Prefer repos already
seen in automation memory, then repos with open CRs in prior heartbeats, then
remaining `lastgit list` slugs in list order. If caps leave entries unscanned,
include `flagged=lastgit-repo-scan-capped:<remaining-count>` or
`flagged=lastgit-cr-scan-capped:<slug>:<remaining-count>` in the heartbeat and
exit `ok` after filing/updating cards for any stuck CRs you did inspect.

In fallback mode, treat an inspected CR as stuck when it has been open for
more than 10 minutes (from CR events, CR view metadata, or automation-memory
first-seen time) and any of these hold:

- required CI is `success` / green but the CR is still open;
- required CI is `failure` / red for the current head oid;
- required CI is missing/pending with no update for more than 10 minutes;
- CR events or forge/completer output show repeated `merge_conflict` or
  `status_not_green`;
- `auto_merge` is false but the CR body, card, or memory says it was opened
  for auto-merge.

Younger than 10 minutes with CI still running is normal lag, not stuck.
If the fallback scan finds no stuck CRs, heartbeat
`noop no-stuck-crs flagged=lastgit-stuck-cmd-missing` and EXIT.

Only heartbeat `error` when both the preferred detector and the fallback
detection route fail before you can determine whether stuck CRs exist.

### 2. Prefer complete-only first
For each `reason=green_unmerged` with `agent_fixable=true`:
```bash
"$timeout_bin" 60s lastgit cr complete <repo> --once --json
```
Re-run stuck for that repo if needed. Completer lag should clear without a
worktree.

### 3. HEAVY — fix ONE agent_fixable CR this wake
Prefer order:

1. `green_merge_conflict`
2. `red_ci` / `missing_ci` / `pending_ci` (mechanical only)
3. remaining `green_unmerged` after complete failed

For the chosen CR:

1. `git fetch lastgit` in an isolated worktree on the **CR head branch**
2. Merge or rebase onto current `main` / base
3. Resolve **mechanical** conflicts only
4. Run repo `.lastgit/ci.sh` (or narrow VERIFY)
5. `git push lastgit HEAD:<head-branch>`
6. Wait for green `lastgit ci status <new-oid> --repo <slug>` (sleepless
   `lastgit ci watch --repo … --ref … --timeout-ms …` once is fine)
7. `lastgit cr complete <repo> --once --json`

If product judgment is required: file/update one P0 card (tags
`pipeline,p0,merge,agent-runnable`), body with CR id + conflict files +
`BLOCKED:` only for true human gates, rank todo, EXIT.

### 4. File the rest
For every other stuck entry you did not fix, including fallback-detected stuck
CRs: file or update one deduped P0
kanban card (`kanban search` first) so pickup reclaim can own it. Include:

```
Repo: EdgeVector/<slug>
Base: main
Kind: pr
Priority: P0
Tags: pipeline,p0,merge,agent-runnable,lastgit

## GOAL
Clear stuck LastGit CR <cr_id> (reason=<reason>).

## CONTEXT
lastgit stuck/fallback scan: <detail>
head_oid: <oid>

## STEPS
1. worktree on head branch
2. rebase/merge main; resolve mechanical conflicts
3. .lastgit/ci.sh; push; lastgit cr complete
```

### 5. Heartbeat
```
merge-babysit <ISO> ok|noop|error stuck=<n> fixed=<n> filed=<n> reasons=<…>
```

Use `ok` when you fixed or filed, including when fallback detection filed cards.
Use `noop` when stuck count was 0. Use `error` only when detection itself failed
and no fallback result could determine the stuck set.

## DONE-WHEN (per wake)
- stuck list empty after complete, OR
- one mechanical CR advanced (new head and/or merged), OR
- every remaining stuck CR has a live P0 card

## Guardrails
- Never force-merge around red required checks
- Never edit shared checkouts in place (`git worktree add`)
- Never spawn background agents; you ARE the worker for at most one CR
- Do not recreate `~/.lastgit/code`
