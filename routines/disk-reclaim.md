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
   **Liveness gates (won't-undo — 2026-08-17 free-collapse):** the helper's
   process probe (`ps`/`lsof`) may fail under a scheduled sandbox while the
   board still answers. Interpret helper output as:
   - **Hard stop** (`exit 3`, `liveness_unavailable=1`, no `liveness_soft=1`):
     process table missing **and** no real board protect set. Do **not** hand-
     delete worktrees. Heartbeat `error liveness_unavailable=1 …`.
   - **Soft degrade** (`exit 0`, `liveness_soft=1`): process table missing but
     board protect is real. The helper still reclaims finished non-`doing`
     worktrees (no pressure strip). Count `reclaim finished` / `removed`
     lines as `worktrees_pruned`. Heartbeat `ok liveness_soft=1
     worktrees_pruned=<n> …` when it reclaimed, or `ok liveness_soft=1
     worktrees_pruned=0 …` when the protect set + age gate left nothing
     eligible (that is a real empty result, not a blind abort).
   - Never treat soft-degrade as a reason to skip backup/scratch retention or
     free-space escalation below — those steps do not need process inspection.
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
4b. **Stale LastDB scratch copies (helper — never raw `rm`).** Run:
   ```bash
   "$last_stack/bin/last-stack-scratch-reclaim" --execute
   ```
   The helper encodes the whole 4b contract: scope
   (`~/.lastdb-test-copies/*` >48h, `~/lastdb-ephemeral-*` >48h,
   `~/.lastdb.broken-*` >7d), the keep names (`flip-records*`, `pin-*`,
   `keep-*`), the per-candidate guardrail (real dir, realpath outside
   `~/.lastdb`, empty `lsof +D`, not named in a doing card — board
   unreadable fails CLOSED), and the `*-REPORT.md` salvage into
   `flip-records/` before deletion. Do NOT issue `rm -rf` for these paths
   yourself: the managed execution policy rejects agent-issued `rm -rf`
   command lines, which is exactly why audited candidates sat undeleted for
   days (papercut-disk-reclaim-deletion-policy-blocks-approved-candidates).
   Map the helper's `scratch_reclaimed=<n>` to the heartbeat token
   `lastdb_copies_pruned=<n>`; carry `scratch_delete_failed` /
   `scratch_board_unavailable` / `scratch_lsof_unavailable` into the
   heartbeat unchanged when present — a block is an `error`, not
   `ok reclaimed_gb=0`.
4c. **VM sparse-disk overhang (helper — the host cannot see it).** Space
   deleted inside the colima/Docker VM does not return to the host volume
   until something trims it. On 2026-08-23 one `fstrim -a` inside the VM
   returned **79.6 GiB** to the host, and no counter in this routine could see
   it: step 3c sizes `~/.cache`, not the VM disk image. Run:
   ```bash
   "$last_stack/bin/last-stack-vm-disk-trim" --free-below-gib 100
   ```
   The helper owns every guard rail: a weekly throttle stamp, the free-space
   ceiling above, docker-absent and daemon-unreachable clean noops, and an
   image-must-already-be-local gate so no run ever pulls unattended. Carry its
   `vm_trimmed_gb=<n>` into the heartbeat. A `vm_trim_skipped=docker-unreachable`
   token is the EXPECTED result inside the routine sandbox, not an error: the
   weekly `com.edgevector.vm-disk-trim` LaunchAgent runs the same helper from
   the host session, where the docker socket is reachable. Report
   `vm_trim_skipped=<reason>` unchanged when present.

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
     after reclaim" --kind other --system host-disk --summary "host disk below 60 GiB after reclaim"`) so every agent sees it.
     Do not post a duplicate if an unexpired low-disk notice from a prior run
     is already up.
   - **< 30 GiB free:** additionally run the step-5 aggressive purge even if
     it was skipped, tighten step-4a retention to newest 1 for this run only,
     and file `papercut-low-disk-emergency` through `brain papercut file`
     (`--component disk --severity p0 --kind specified-fix`) with a one-line
     observable symptom plus `df -h`, the largest remaining consumers, and
     prevention evidence in the body. If the typed record is already open,
     append the fresh evidence with `brain append ... --type papercut`; never
     generic `brain put`. The keyed filing must succeed before reporting it as
     queued. This is the last line of defense — never end below 30 GiB silently.

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

**`reclaimed_gb=0` is a claim that needs evidence, not a default.** Before
emitting a zero, state which of these it was:
- nothing was eligible (say how many candidates you examined), or
- something *prevented* you from acting.

The second case must never be reported as `ok`. If the reclaim helper exits
**3** / logs `liveness_unavailable=1` **without** `liveness_soft=1`, it could
not read the process table **and** had no board protect set — heartbeat
`error liveness_unavailable=1`, not `ok reclaimed_gb=0`. Soft-degrade
(`liveness_soft=1`) is different: worktree reclaim may still have run; report
the measured `worktrees_pruned` and do not hard-error solely for soft
liveness. Same hard-error rule for a board read that failed
(`board_unavailable`) or a `situations preflight` you could not run when
those failures blocked the only remaining safe reclaim path.
This distinction is the whole ballgame: for weeks of hourly runs, a blind
routine and an idle machine emitted the identical line `ok reclaimed_gb=0`,
while the worktree pool grew to 75 trees and the git cache to 38 GB. On
2026-08-16→17 the opposite failure mode appeared: every hourly fire hard-
aborted on sandbox-denied `ps` (`liveness_unavailable=1 reclaimed_gb=0`)
while free space fell ~100 GiB with `board_ok=1` — soft-degrade closes that.

**Free-space collapse with zero reclaim (won't-undo):** keep the previous
run's `final_free` GiB in automation memory (`prev_final_free_gib=<n>`).
After this run's reclaim steps, if `reclaimed_gb=0` and
`worktrees_pruned=0` and free dropped by **>20 GiB** vs the previous stored
value, heartbeat `error free_collapsing_with_zero_reclaim drop_gib=<n>
final_free=<free> prev_free=<prev>` (plus the usual counters) so
morning-sync / factory-health see a loud signal — not a silent identical
hourly red. Always rewrite `prev_final_free_gib` at end of a successful
assessment even when outcome is error.

Also report `pool_size=<n worktrees>` every run. A count that climbs across
consecutive runs is the signal that a *generator* is outpacing this sweep —
that is a card against the generator (reclaim-on-exit), not a reason to widen
the sweep.

> **Heartbeat (LAST action, always — even a bounded no-op).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "disk-reclaim
> <ISO-ts> <ok|noop|error> <outcome>"`, e.g. `ok reclaimed_gb=<n>
> worktrees_pruned=<n> backups_pruned=<n> lastdb_copies_pruned=<n>
> vm_trimmed_gb=<n> final_free=<free>` (plus `low_disk=<free>` whenever step 6 tripped) on a real
> reclaim, or `noop reclaimed_gb=0 worktrees_pruned=0` when the run found
> nothing to remove. Without this call,
> routinesd's outcome classifier has no ok/noop/error token to key on and
> reports `lastOutcome=unknown` for every finished run regardless of how the
> run actually went. If the heartbeat helper cannot write because the brain
> socket is unavailable, still print the heartbeat line so the run's stdout
> carries the token.

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
