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

## Operator flags — what protects a live build, and how to override it

`bin/last-stack-worktree-reclaim` refuses to strip a worktree's build caches
when the tree looks live. Four predicates decide that, and each one names itself
in the log so an agent can see why a path was spared.

| log reason | what it detected |
|---|---|
| `live_cwd` | a running process has its cwd inside the worktree |
| `live_exec_image` | a running process's executable image lives under the tree's `target/` |
| `fresh_build_marker` | cargo fingerprints under `target/` are newer than the freshness window |
| `pressure_skip` | the volume is not under disk pressure, so no broad strip ran at all |

| variable | default | effect |
|---|---|---|
| `LAST_STACK_RECLAIM_FREE_FLOOR_GIB` | `80` | Free GiB below which a broad generated-cache strip is allowed. At or above the floor the sweep logs `pressure_skip broad_sweep_skipped_disk_pressure` and strips nothing. Set `0` to never strip on pressure grounds; set very high to force stripping. |
| `LAST_STACK_RECLAIM_BUILD_FRESH_MIN` | see script | Minutes a cargo fingerprint counts as a live build. |
| `LAST_STACK_RECLAIM_SKIP_BOARD` | unset | Skip the board read that protects `doing` worktrees. Tests only. |
| `LAST_STACK_RECLAIM_SKIP_LSOF` | unset | Skip the `lsof` cwd sweep. Tests only, or when process inspection is unavailable. |
| `LAST_STACK_RECLAIM_EXTRA_LIVE_PATHS` | unset | Extra paths to treat as `live_cwd`. |
| `LAST_STACK_RECLAIM_EXTRA_LIVE_EXEC_PATHS` | unset | Extra executable images to treat as `live_exec_image`. |

CAUTION: `LAST_STACK_RECLAIM_FREE_FLOOR_GIB` reads as a threshold to strip
BELOW, not above. A high value means "always under pressure", so a high value
strips more, not less. `0` means the volume is never under pressure.

The `SKIP_*` flags exist for the fixtures and for a host where process
inspection is unavailable. Do not set them in a scheduled run: without process
proof the sweep cannot see a live build, and stripping then deletes build
outputs from under it.

Both guards are proven by `tests/last-stack-worktree-reclaim.sh` and
`tests/last-stack-disk-reclaim-stripped-path.sh`, which run in the required
`.lastgit/ci.sh` gate rather than only under `LAST_STACK_CI_FULL=1`.

## Output
Report: GB reclaimed, worktrees pruned (and which were kept and why), final free
space, and anything left for a human.

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
