---
name: worktree-cleanup
cadence: daily (off-hours)
description: Prune stale worktrees and branches, reconcile local commits/PRs/board state, bring each repo to its latest default branch, and keep the machine healthy — without touching in-progress work.
---

You are running an unattended off-hours machine-hygiene routine for `<WORKSPACE>`.
Nobody is available — don't wait for a human. Keep the machine able to build and
code: prune stale worktrees/branches, bring repos to latest, reclaim disk if
needed, and turn coherent local work into draft PRs instead of letting it rot in
shared checkouts. Then report what you did and what's left.

## Run Budget And Exit Contract
Treat this as a bounded foreground routine. Immediately after CLI preflight,
record:

```bash
run_started_epoch="$(date -u +%s)"
run_timeout_min="${ROUTINES_TIMEOUT_MIN:-${TIMEOUT_MIN:-30}}"
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
```

Before each expensive phase (repo-wide worktree enumeration, open-PR inventory,
port scans, large `du`, cache deletion, fetch/pull sweeps, or memory/report
writes), recompute elapsed/remaining:

```bash
elapsed=$(( $(date -u +%s) - run_started_epoch ))
remaining=$(( run_timeout_min * 60 - elapsed ))
```

Do not start a new expensive phase when fewer than 10 minutes remain. Stop,
write the best available report/memory note, heartbeat
`worktree-cleanup <ISO-ts> ok result=budget-handoff ...` if useful work already
happened, or `noop result=budget-exhausted` if nothing changed, then print the
`ROUTINE_RESULT` token followed by
`outcome=<ok|noop> detail=<same-one-line-outcome>` and EXIT. A bounded handoff
is not a routine error.

Long foreground commands must be self-timeboxed by the shell, not left for
routinesd to kill. Wrap `find`, `lsof`, `du`, `rm -rf`, `git fetch --all`,
open-PR inventory, and other potentially slow probes as
`timeout -k 30s <seconds> ...` or `gtimeout -k 30s <seconds> ...`, choosing a
timeout that leaves the 10-minute closeout reserve. If no timeout binary is
available, skip the long phase and report `reason=no-command-timebox` instead
of starting it. If a command times out, keep any completed cleanup, report
`reason=command-timebox phase=<phase>`, heartbeat, print the `ROUTINE_RESULT`
token followed by `outcome=<ok|noop> detail=<same-one-line-outcome>`, and EXIT
instead of chaining into another slow phase.

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

## 🛑 Hard guardrails — obey exactly (violations cause data loss / outages)
- NEVER remove a worktree that has **uncommitted changes**
  (`git -C <wt> status --porcelain` non-empty) OR **unique unmerged commits**
  (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>` shows any `+`).
- There is no `review` column. Board columns are only `backlog`, `todo`,
  `doing`, and `done`.
- NEVER touch a worktree whose **board card is in `doing`** — read
  the board first (`<board list command>`) and cross-check by intent (a slug may
  not string-match the worktree/branch name).
- Keep any `salvage-*` / `tombstone-*` / `locked` worktree.
- NEVER kill the process hosting your **brain/board node**, and never kill
  another agent's process. NEVER `stash`/`reset`/`checkout --` in a shared repo.
- NEVER silently discard dirty source. You may remove only proven generated or
  cache artifacts, or stale patches whose source branch/PR is proven merged or
  closed-unneeded. When in doubt, preserve a patch under `/tmp` and report it.
- If the board is unreachable or returns `service_timeout`, "node did not
  respond", "too many concurrent reads", or `uds_connection_limit`, do not run
  doctor/init/restart. Treat it as shared backpressure: skip any cleanup whose
  safety depends on board state, heartbeat `noop board-socket-unavailable
  skipped=<phase>`, print the `ROUTINE_RESULT` token followed by
  `outcome=noop detail=board-socket-unavailable skipped=<phase>`, and EXIT if
  no independent cleanup is safe.

## Procedure each run
0. **Normalize the scheduled shell.** Source the Last Stack PATH prelude and
   preflight the global CLIs before shell-heavy work:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   last_stack_require_tools git curl jq gh find rm <board-cli> <brain-cli>
   ```
1. **Discover repo roots before any repo-level Git command.** The workspace
   root may be only a container directory, so do not run root-level Git probes
   there first. Enumerate child repos, then run Git against each discovered repo:
   ```bash
   workspace="<WORKSPACE>"
   last_stack_run_tool "$LAST_STACK_TOOL_FIND" "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
     | while IFS= read -r git_dir; do
         repo="${git_dir%/.git}"
         last_stack_run_tool "$LAST_STACK_TOOL_GIT" -C "$repo" rev-parse --show-toplevel
       done
   ```
   Use the resulting repo roots to enumerate worktrees authoritatively across
   every repo and every worktree location you use (e.g. a dedicated worktrees
   dir, per-repo `.worktrees/`, top-level siblings). For each repo, run
   `git -C "$repo" worktree list --porcelain`. Derive each worktree's owning
   repo from `git -C <path> rev-parse --git-common-dir`.
2. **Classify each worktree.** Compute: its branch, unique-commit count
   (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>`), dirty-file count
   (`git -C <wt> status --porcelain`), and whether a live process is cwd'd in it.
   A worktree is **REMOVABLE only if** it has 0 unique commits AND a clean tree
   AND its board card is not `doing`. Otherwise LEAVE IT.
   If you store command output in shell variables, do not name one `status`;
   `zsh` treats `status` as a read-only special parameter. Use a specific name
   such as `repo_status` or `git_status`.
3. **Remove the removable ones.** `last_stack_run_tool "$LAST_STACK_TOOL_GIT" -C
   <repo> worktree remove --force <path>` then `last_stack_run_tool
   "$LAST_STACK_TOOL_GIT" -C <repo> branch -D <branch>` for a fully-merged
   branch. Run `last_stack_run_tool "$LAST_STACK_TOOL_GIT" -C <repo> worktree
   prune` per repo afterwards. Delete any now-empty
   worktree parent dir.
3a. **Reap stale dev-server port orphans (port-scoped, brain-safe).** Local
   preview / dev servers (e.g. Vite, a per-app dev node) bind well-known ports;
   when their launching session dies the process can outlive it and keep holding
   the port, so the next preview/dev run can't bind and an agent stalls. Reap
   ONLY those orphans, identified by **port + command line** — never by a process
   *name* (your brain/board node may share the same binary name).
   - For each known preview/dev-server port (`lsof -ti :<port>` for each of your
     `<preview/dev-server ports>`), inspect every listener's full command line
     (`ps -o command= -p <pid>`).
   - **Kill a PID only if BOTH hold:** (a) its command line matches your
     preview/dev-server launch pattern (e.g. the `run.sh` / `vite` dev invocation
     for that port), AND (b) it is NOT your live brain/board node — confirm by
     the node's own identity (its Unix socket / data dir / launch flags via
     `lsof <your node socket>` or `lsof -i :<your node port>`), NEVER by the
     binary name. A long uptime is NOT an orphan signal.
   - Skip any listener whose owning session is still alive or whose cwd is a
     `doing` board worktree. Log each PID + port + command line you
     reaped (and each you deliberately spared and why).
   This is the port-scoped sibling of the worktree-orphan reap in step 3 — same
   "prove it's a disposable orphan, never your node" discipline, but keyed on a
   held port rather than a removable worktree.
4. **Audit dirty shared checkouts and local-only work.** For every primary repo
   checkout, collect `git -C <repo> status -sb`, unpushed branch commits
   (`git -C <repo> log --branches --not --remotes --oneline`), and open PRs for
   the same owner/repo. Classify each dirty checkout:
   - Generated/cache-only: remove only ignored or known generated artifacts
     such as build output, dependency caches, or local node/runtime data dirs.
   - Stale reverse-diff or misplaced patch: preserve a patch under `/tmp` if it
     is not trivially generated, then restore only paths proven to be stale by
     comparing against `origin/<DEFAULT_BRANCH>` and merged/closed PR state.
   - Coherent source/docs/config work: create or reuse a `codex/<slug>` branch
     from the default branch, apply only the intended files, run lightweight
     repo checks, commit, push, and open a draft PR. Do not mix unrelated work
     into one PR.
   - Cross-repo generated artifacts or handoff files: keep them uncommitted when
     no consumer PR exists yet, and include the exact path and reason in the
     residual report.
5. **Reconcile PR and board state.** Read open PRs and the board before changing
   statuses. If a board card in `doing` points at a merged PR and its end state
   is proven, move it to `done`. If it points at a closed-unmerged PR, update
   the body with the blocker or replacement path, and leave it in the earliest
   accurate non-terminal column. If coherent local work has no PR, open a draft
   PR. If CI is red or pending, leave it for the CI/drain routine unless the fix
   is clearly inside this cleanup's local-change scope.
6. **Bring repos to latest.** Run the maintained repark helper — do NOT
   hand-roll fetch/pull loops (`fetch --all` hammers the primary LastDB node
   via lastdb:// remotes, and ad-hoc recipes are how the 2026-07-19 drift
   happened: fold 134 behind, last-stack 256):
   ```bash
   "$HOME/.last-stack/bin/last-stack-repark-shared-checkouts" || true
   ```
   It is venue-aware, salvage-first, skips repos with fresh edits, and never
   resets or pushes. Surface every `FLAG` line in your report verbatim —
   `ahead`/`diverged` flags need an interactive audit, not an unattended fix.
   Contract: brain `sop-shared-checkout-mirror-contract`.
7. **Reclaim disk if needed** (see the `disk-reclaim` routine for the full,
   safer procedure — this routine may reuse it). Delete build-artifact dirs
   (`target/`, `node_modules/` in throwaway worktrees, caches) — removing a build
   cache never touches source. If you're below your disk floor, prune the
   largest reclaimable caches first.
8. **Prevention upkeep.** Apply whatever stops the buildup from recurring in your
   stack (e.g. a periodic build-cache sweep, a disk-floor check). Don't change
   global environment unattended — note a recommendation in the report instead.
9. **Stale agent sessions.** If your harness lets you *enumerate* stale sessions
   but *archiving* is blocked unattended, list the safe-to-archive ones in your
   report for a manual sweep. Do NOT kill agent processes or the brain/board
   node.

## Output
Report: what you pruned (and what you KEPT and why), which repos were brought to
latest, draft PRs opened or updated, board corrections made, stale artifacts
removed, GB reclaimed + final free space, and anything left for a human. Include
the exact residual dirty paths and why each one was intentionally left.

> **Heartbeat (LAST action, always).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "worktree-cleanup
> <ISO-ts> <ok|noop|error> <one-line-outcome>"`. Use `ok` when any cleanup,
> PR, or board correction happened; `noop` for bounded no-action, busy-node, or
> budget-exhausted exits; and `error` only for a real routine fault that was not
> safely bounded. If the heartbeat helper cannot write, still print the
> heartbeat line to stdout. Then print the `ROUTINE_RESULT` token followed by
> `outcome=<ok|noop|error> detail=<same-one-line-outcome>` and EXIT.
