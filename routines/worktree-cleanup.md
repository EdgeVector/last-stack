---
name: worktree-cleanup
cadence: daily (off-hours)
description: Prune stale worktrees and branches across all repos, bring each repo to its latest default branch, and keep the machine healthy — without touching in-progress work.
---

You are running an unattended off-hours machine-hygiene routine for `<WORKSPACE>`.
Nobody is available — don't wait for a human. Keep the machine able to build and
code: prune stale worktrees/branches, bring repos to latest, reclaim disk if
needed. Then report what you did and what's left.

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

## Procedure each run
1. **Enumerate worktrees authoritatively** across every repo and every worktree
   location you use (e.g. a dedicated worktrees dir, per-repo `.worktrees/`,
   top-level siblings). For each repo:
   `git -C <repo> worktree list --porcelain`. Derive each worktree's owning repo
   from `git -C <path> rev-parse --git-common-dir`.
2. **Classify each worktree.** Compute: its branch, unique-commit count
   (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>`), dirty-file count
   (`git -C <wt> status --porcelain`), and whether a live process is cwd'd in it.
   A worktree is **REMOVABLE only if** it has 0 unique commits AND a clean tree
   AND its board card is not `doing`/`review`. Otherwise LEAVE IT.
3. **Remove the removable ones.** `git -C <repo> worktree remove --force <path>`
   then `git -C <repo> branch -D <branch>` for a fully-merged branch. Run
   `git -C <repo> worktree prune` per repo afterwards. Delete any now-empty
   worktree parent dir.
4. **Bring repos to latest.** `git -C <repo> fetch --all --prune` then fast-
   forward the default branch. Agents work in worktrees, so switching the main
   checkout's branch doesn't disturb them — but never force or discard.
5. **Reclaim disk if needed** (see the `disk-reclaim` routine for the full,
   safer procedure — this routine may reuse it). Delete build-artifact dirs
   (`target/`, `node_modules/` in throwaway worktrees, caches) — removing a build
   cache never touches source. If you're below your disk floor, prune the
   largest reclaimable caches first.
6. **Prevention upkeep.** Apply whatever stops the buildup from recurring in your
   stack (e.g. a periodic build-cache sweep, a disk-floor check). Don't change
   global environment unattended — note a recommendation in the report instead.
7. **Stale agent sessions.** If your harness lets you *enumerate* stale sessions
   but *archiving* is blocked unattended, list the safe-to-archive ones in your
   report for a manual sweep. Do NOT kill agent processes or the brain/board
   node.

## Output
Report: what you pruned (and what you KEPT and why), which repos were brought to
latest, GB reclaimed + final free space, and anything left for a human.
