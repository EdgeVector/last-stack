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

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

## 🛑 Hard guardrails — obey exactly (violations cause data loss / outages)
- NEVER remove a worktree that has **uncommitted changes**
  (`git -C <wt> status --porcelain` non-empty) OR **unique unmerged commits**
  (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>` shows any `+`).
- NEVER touch a worktree whose **board card is in `doing` or `review`** — read
  the board first (`<board list command>`) and cross-check by intent (a slug may
  not string-match the worktree/branch name).
- Keep any `salvage-*` / `tombstone-*` / `locked` worktree.
- NEVER kill the process hosting your **brain/board node**, and never kill
  another agent's process. NEVER `stash`/`reset`/`checkout --` in a shared repo.
- NEVER silently discard dirty source. You may remove only proven generated or
  cache artifacts, or stale patches whose source branch/PR is proven merged or
  closed-unneeded. When in doubt, preserve a patch under `/tmp` and report it.
- If the board is unreachable, run the doctor command, report the outage, and
  continue only with cleanup steps that do not depend on board state.

## Procedure each run
1. **Discover repo roots before any repo-level Git command.** The workspace
   root may be only a container directory, so do not run root-level Git probes
   there first. Enumerate child repos, then run Git against each discovered repo:
   ```bash
   workspace="<WORKSPACE>"
   find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
     | while IFS= read -r git_dir; do
         repo="${git_dir%/.git}"
         git -C "$repo" rev-parse --show-toplevel
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
   AND its board card is not `doing`/`review`. Otherwise LEAVE IT.
   If you store command output in shell variables, do not name one `status`;
   `zsh` treats `status` as a read-only special parameter. Use a specific name
   such as `repo_status` or `git_status`.
3. **Remove the removable ones.** `git -C <repo> worktree remove --force <path>`
   then `git -C <repo> branch -D <branch>` for a fully-merged branch. Run
   `git -C <repo> worktree prune` per repo afterwards. Delete any now-empty
   worktree parent dir.
4. **Audit dirty shared checkouts and local-only work.** For every primary repo
   checkout, collect `git -C <repo> status -sb`, unpushed branch commits
   (`git -C <repo> log --branches --not --remotes --oneline`), and open PRs for
   the same owner/repo. Classify each dirty checkout:
   - Generated/cache-only: remove only ignored or known generated artifacts
     such as `.folddb-dev`, build output, or local node/runtime caches.
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
   statuses. If a board card in `review` points at a merged PR, move it to
   `done`. If it points at a closed-unmerged PR, move it out of `review`, update
   the body with the blocker or replacement path, and leave it in the earliest
   accurate column. If coherent local work has no PR, open a draft PR. If CI is
   red or pending, leave it for the CI/drain routine unless the fix is clearly
   inside this cleanup's local-change scope.
6. **Bring repos to latest.** `git -C <repo> fetch --all --prune` then fast-
   forward the default branch. Agents work in worktrees, so switching the main
   checkout's branch doesn't disturb them — but never force or discard.
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
