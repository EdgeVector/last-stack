---
name: disk-reclaim
cadence: hourly
description: Hourly disk-space reclaim — prune merged/clean worktrees, sweep orphan build processes, sweep stale build caches, and purge below the disk floor. The disk-focused subset of worktree-cleanup; does not pull repos or ship code.
---

Hourly disk-space reclaim for `<WORKSPACE>`. Runs unattended every hour — make
safe choices, never block on questions, end with a one-paragraph report of what
was reclaimed and current free space (`df -h`).

This is the DISK-FOCUSED subset of the `worktree-cleanup` routine: do NOT pull
repos to latest, do NOT enumerate/archive sessions, do NOT file cards. Just
reclaim disk safely.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

## 🛑 Hard guardrails (violating these has caused outages — obey exactly)
- NEVER kill the process hosting your **brain/board node**. Identify it first
  (e.g. `lsof -i :<your node port>`); only ever kill an *orphan* build/server
  process that sits inside a worktree you've already confirmed is safe to remove
  AND is not your live node.
- NEVER kill an agent process. NEVER `stash`/`reset`/`checkout --` in a shared
  repo.
- NEVER remove a worktree with uncommitted changes
  (`git -C <wt> status --porcelain` non-empty) OR unique unmerged commits
  (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>` shows any `+`). Keep
  `salvage-*` / `tombstone-*` / `locked` worktrees.
- NEVER touch a worktree whose board card is in `doing`/`review`. Read the board
  first (`<board list command>`) and cross-check by intent.

## Procedure each run
1. **Assess.** `df -h <data volume> | tail -1`; list any build/server processes
   and confirm which one is your live brain/board node so you never touch it.
2. **Enumerate worktrees** across all repos + all worktree locations via
   `git -C <repo> worktree list --porcelain`; derive each one's repo from
   `git -C <path> rev-parse --git-common-dir`.
3. **Per worktree, compute** branch, unique-commit count, dirty count, and
   whether a live process runs in it. A worktree is REMOVABLE only if 0 unique
   commits AND clean AND its card isn't `doing`/`review`. If it has a live orphan
   process (verify its command path is inside the worktree and it is NOT your
   node), kill that PID first, then `git worktree remove --force <path>` and
   `git branch -D <branch>`. Then `git worktree prune` per repo. Remove a now-
   empty worktree parent dir.
4. **Prevention.** Sweep stale build caches older than a few days (e.g. a
   `cargo sweep`/`go clean`/`node_modules` prune equivalent for your stack).
   Confirm any incremental-build cache cap is in effect; note it if not (don't
   change global env unattended).
5. **Disk floor.** If free space < `<your floor, e.g. ~30 GB>`, proactively purge
   the largest reclaimable build-cache dir with an **atomic swap** so an active
   build doesn't see a half-deleted tree: `mv target target.PURGE` → recreate an
   empty `target/` → `rm -rf target.PURGE` in the background. Stop active
   compiles first (kill the compiler processes, NOT the node). Never blow away a
   shared build cache while you're still above the floor.

## Output
Report: GB reclaimed, worktrees pruned (and which were kept and why), final free
space, and anything left for a human.
