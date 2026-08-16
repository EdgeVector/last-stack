---
name: disk-reclaim
cadence: hourly
description: Hourly disk-space reclaim — prune merged/clean worktrees, sweep orphan build processes, sweep stale build caches, apply LastDB backup/test-copy retention, and escalate below the disk floor. The disk-focused subset of worktree-cleanup; does not pull repos or ship code.
---

Hourly disk-space reclaim for `<WORKSPACE>`. Runs unattended every hour — make
safe choices, never block on questions, end with a one-paragraph report of what
was reclaimed and current free space (`df -h`).

This is the DISK-FOCUSED subset of the `worktree-cleanup` routine: do NOT pull
repos to latest, do NOT enumerate/archive sessions, do NOT file cards. Just
reclaim disk safely.

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

## 🛑 Hard guardrails (violating these has caused outages — obey exactly)
- NEVER kill the process hosting your **brain/board node**. Identify it first
  (e.g. `lsof -i :<your node port>`); only ever kill an *orphan* build/server
  process that sits inside a worktree you've already confirmed is safe to remove
  AND is not your live node.
- NEVER kill an agent process. NEVER `stash`/`reset`/`checkout --` in a shared
  repo.
- NEVER touch a worktree whose board card is in **`doing`**. Read the board
  first (`<board list command>`) and cross-check by intent. Keep
  `salvage-*` / `tombstone-*` / `locked` worktrees and any cwd with a live
  agent/build process.
- **Dirty is no longer a permanent keep** (Tom 2026-07-30). Abandoned dirty
  trees were the multi‑tens‑of‑GB fkanban pile. Prefer
  `bin/last-stack-worktree-reclaim` which: (1) always strips
  `target`/`node_modules`/`.next`/`dist`/`build`, (2) saves a patch under
  `~/.local/state/last-stack/runtime/worktree-patches/` when dirty, then
  (3) `git worktree remove --force`. Do **not** silently discard without a
  patch when the tree has real source edits — the helper does the patch step.
- Unique unmerged commits on a non-`doing` tree older than the age gate may
  still be reclaimed after the patch save; the branch is kept if not fully
  merged (`branch -d` only, never `-D` unique WIP).
- NEVER touch the live LastDB home (`~/.lastdb`), any `lastdb-backup-pre-*`
  pinned rollback backup outside `~/.lastdb-backups/`, or an in-place retained
  engine tree while a soak/rollback card is open. LastDB pruning below is scoped
  EXCLUSIVELY to `~/.lastdb-backups/`, `~/.lastdb-test-copies/`,
  `~/lastdb-ephemeral-*`, and `~/.lastdb.broken-*`. Before ANY such rm: the
  candidate must be a real directory (`[ ! -L "$p" ]`), its realpath must NOT
  resolve inside `~/.lastdb`, and `lsof +D "$p"` must be empty (2026-07-19: a
  smoke path once symlinked the primary — the readlink guard is load-bearing).

## Procedure each run
0. **Normalize the scheduled shell.** Source the Last Stack PATH prelude and
   preflight the global CLIs before shell-heavy work:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   last_stack_require_tools git curl jq find rm bash date basename wc tr df tail ps lsof mkdir mv readlink <board-cli>
   ```
   After this point, do not run generated shell-heavy cleanup/discovery snippets
   directly with the ambient scheduled-shell `PATH`. Run them through
   `last_stack_run_tool "$LAST_STACK_TOOL_BASH" -c '...'` so the snippet
   inherits `LAST_STACK_PRELUDE_PATH`, or call each tool through
   `last_stack_run_tool "$LAST_STACK_TOOL_<NAME>" ...`.
1. **Assess.** `df -h <data volume> | tail -1`; list any build/server processes
   and confirm which one is your live brain/board node so you never touch it.
2. **Discover repo roots before any repo-level Git command.** The workspace
   root may be only a container directory, so do not probe it as a checkout.
   Enumerate child repos first, then run Git against each repo:
   ```bash
   workspace="<WORKSPACE>"
   last_stack_run_tool "$LAST_STACK_TOOL_BASH" -c '
     set -euo pipefail
     workspace="$1"
     find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
       | while IFS= read -r git_dir; do
           repo="${git_dir%/.git}"
           git -C "$repo" rev-parse --show-toplevel
         done
   ' sh "$workspace"
   ```
   Use those repo roots to enumerate worktrees across all repos + all worktree
   locations via `git -C "$repo" worktree list --porcelain`; derive each one's
   repo from `git -C <path> rev-parse --git-common-dir`.
3. **Reclaim worktrees (preferred: helper).** Run the shared reclaim helper
   first — it encodes the 2026-07-30 policy (strip build caches always; age-gate
   non-`doing` trees; dirty → patch then remove):
   ```bash
   "$last_stack/bin/last-stack-worktree-reclaim" --sweep-stale --max-age-hours 48
   ```
   Heartbeat tokens: count lines with `removed worktree` / `stripped` from
   helper stdout if useful. Fallback if the helper is missing: per worktree,
   strip `target`/`node_modules`, then remove only when clean + not `doing` +
   no live cwd. Never leave multi‑GB `target/` dirs behind even when keeping a
   tree.
3a. **Migrate legacy repo-local `.worktrees/` after the live audit.** Disk
   reclaim must not delete non-removable worktrees just because they live under
   a checkout. After the board/lsof audit above, run the bounded migration
   helper so clean idle survivors move to the canonical kanban worktree pool:
   ```bash
   "$HOME/.last-stack/bin/last-stack-migrate-repo-local-worktrees" \
     --workspace "$workspace" \
     --dest "${WORKTREES_DIR:-$HOME/.kanban/worktrees}" || true
   ```
   Report every `FLAG ... kept ...` line. The helper skips dirty paths, live or
   open paths, protected names, non-owned directories, and destination
   collisions.
3b. **Reap stale dev-server port orphans (port-scoped, brain-safe).** A preview /
   dev server (Vite, a per-app dev node) whose launching session died can outlive
   it and keep holding its port, blocking the next run. For each known
   preview/dev-server port (`lsof -ti :<port>` for each of your
   `<preview/dev-server ports>`), check each listener's full command line
   (`ps -o command= -p <pid>`) and kill a PID ONLY if (a) it matches your
   preview/dev-server launch pattern (the `run.sh` / `vite` invocation) AND (b) it
   is NOT your live brain/board node (confirm by the node's own socket / data dir
   via `lsof <your node socket>` or `lsof -i :<your node port>`, NEVER by binary
   name — uptime is not an orphan signal). Skip any whose session is still alive
   or whose cwd is a `doing`/`review` worktree. Log each PID + port reaped.
4. **Prevention.** Sweep stale build caches older than a few days (e.g. a
   `cargo sweep`/`go clean`/`node_modules` prune equivalent for your stack).
   Confirm any incremental-build cache cap is in effect; note it if not (don't
   change global env unattended).
3c. **Account for space OUTSIDE your named counters.** `worktrees_pruned` /
   `backups_pruned` / `lastdb_copies_pruned` describe the categories this
   routine knows about — they say nothing about the rest of the disk. On
   2026-08-15 the single largest reclaimable object on the machine was
   **36 GB of leftover working trees under the git mirror cache**
   (`~/.cache/edgevector-git/*.legacy-checkout`), invisible to every counter
   here, while the routine reported a healthy steady `final_free`. Each run,
   size the top-level directories you do NOT have a counter for, e.g.:

   ```bash
   du -sh "$HOME/.cache/"* 2>/dev/null | sort -rh | head -10
   du -sh "$HOME/code/"*/.routine-worktrees 2>/dev/null | sort -rh | head
   ```

   Report anything above ~5 GB that no counter covers, even when you do not
   act on it. Two traps observed there:
   - A directory named like a cache can be **29 working trees holding 20
     stashes and 213 dirty files**. Check `git status --porcelain` and
     `git stash list` before treating any of it as disposable.
   - `du` on such a directory tells you nothing about how much *history* is
     stored: one 16 GB checkout had a 149 MiB pack and 11 GB of `target/`.
     Use `git count-objects -vH` before concluding a git cache is large.
4a. **LastDB backup retention (`~/.lastdb-backups/` ONLY).** Keep the newest 3
   `pre-*` backup dirs by their trailing timestamp; delete every older one
   (retention set with Tom 2026-07-19 after unbounded backups contributed to
   the ENOSPC that killed routinesd — see brain
   `papercut-lastdb-backups-unbounded-retention`). Before pruning older local
   backups, confirm the off-machine backup path is currently healthy; if that
   cannot be proven, retain the older local backups, heartbeat
   `backup_retention_blocked=off_machine_unverified`, and escalate instead of
   deleting what may be the only copy.

   Apply the LastDB guardrail above to each candidate: real dir, realpath outside
   `~/.lastdb`, and open-file safety. Scope `lsof +D` to the newest 3 retained
   backups plus any candidate newer than 2 days. For older candidates outside
   the retained set, `lsof` failure or inconclusive output is not a permanent
   keep: after the realpath and off-machine checks pass, treat
   `lsof`-inconclusive on a >2-day-old candidate as prunable and report
   `backup_lsof_inconclusive_pruned=<n>` alongside `backups_pruned=<n>`.
   A positive open-file hit still protects that candidate. These dirs are APFS
   clones: report reclaim as the `df` delta, never the `du` sum. Heartbeat
   token: `backups_pruned=<n>`.
4b. **Stale LastDB scratch copies.** Delete: `~/.lastdb-test-copies/*` with
   mtime older than 48h (ALWAYS keep `flip-records*` and anything matching
   `pin-*`/`keep-*`); `~/lastdb-ephemeral-*` older than 48h;
   `~/.lastdb.broken-*` older than 7 days. Same guardrail per candidate. If a
   copy contains a top-level `*-REPORT.md`/`VALIDATE-REPORT.md`, copy that file
   into `~/.lastdb-test-copies/flip-records/` before deleting the tree.
   Heartbeat token: `lastdb_copies_pruned=<n>`.
5. **Disk floor.** If free space < `<your floor, e.g. ~30 GB>`, proactively purge
   the largest reclaimable build-cache dir with an **atomic swap** so an active
   build doesn't see a half-deleted tree: `mv target target.PURGE` → recreate an
   empty `target/` → `rm -rf target.PURGE` in the background. Stop active
   compiles first (kill the compiler processes, NOT the node). Never blow away a
   shared build cache while you're still above the floor.

   Keep this step bounded. After the swap, the routine has already made the live
   path safe; wait at most two minutes for the background delete to finish, then
   report `purge_continuing=<path>` and heartbeat/finish normally if the old
   `*.PURGE*` directory still exists. Do **not** re-enter a large `rm -rf` in the
   foreground or start another purge after the final ten-minute budget window.
   A later disk-reclaim run may resume deleting the stale `*.PURGE*` directory
   using the same bounded-wait rule.
6. **Free-space floor escalation — act while the scheduler still runs.**
   routinesd itself dies on ENOSPC (it did on 2026-07-19, taking the whole
   fleet — including this routine — down for 9 hours), so the floor must
   trigger loudly BEFORE the disk is tight. After all reclaim steps, read the
   final free space:
   - **< 60 GiB free:** add `low_disk=<free>` to the heartbeat line and post a
     Situations notice (`situations notice --title "disk low: <free> free
     after reclaim" --kind other --system host-disk`) so every agent sees it.
     Do not post a duplicate if an unexpired low-disk notice from a prior run
     is already up.
   - **< 30 GiB free:** additionally run the step-5 aggressive purge even if
     it was skipped, tighten step-4a retention to newest 1 for this run only,
     and upsert brain record `papercut-low-disk-emergency` (type reference)
     with `df -h` output and the largest remaining consumers so the papercut
     router files a P0 card. This is the last line of defense — never end a
     run below 30 GiB silently.

## Output
Report: GB reclaimed, worktrees pruned (and which were kept and why), final free
space, and anything left for a human.

**`reclaimed_gb=0` is a claim that needs evidence, not a default.** Before
emitting a zero, state which of these it was:
- nothing was eligible (say how many candidates you examined), or
- something *prevented* you from acting.

The second case must never be reported as `ok`. If the reclaim helper exits
**3** / logs `liveness_unavailable=1`, it could not read the process table and
therefore refused to touch anything — heartbeat `error
liveness_unavailable=1`, not `ok reclaimed_gb=0`. Same for a board read that
failed (`board_unavailable`) or a `situations preflight` you could not run.
This distinction is the whole ballgame: for weeks of hourly runs, a blind
routine and an idle machine emitted the identical line `ok reclaimed_gb=0`,
while the worktree pool grew to 75 trees and the git cache to 38 GB.

Also report `pool_size=<n worktrees>` every run. A count that climbs across
consecutive runs is the signal that a *generator* is outpacing this sweep —
that is a card against the generator (reclaim-on-exit), not a reason to widen
the sweep.

> **Heartbeat (LAST action, always — even a bounded no-op).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "disk-reclaim
> <ISO-ts> <ok|noop|error> <outcome>"`, e.g. `ok reclaimed_gb=<n>
> worktrees_pruned=<n> backups_pruned=<n> lastdb_copies_pruned=<n>
> final_free=<free>` (plus `low_disk=<free>` whenever step 6 tripped) on a real
> reclaim, or `noop reclaimed_gb=0 worktrees_pruned=0` when the run found
> nothing to remove. Without this call,
> routinesd's outcome classifier has no ok/noop/error token to key on and
> reports `lastOutcome=unknown` for every finished run regardless of how the
> run actually went. If the heartbeat helper cannot write because the brain
> socket is unavailable, still print the heartbeat line so the run's stdout
> carries the token.
