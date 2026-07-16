---
name: disk-reclaim
cadence: hourly
description: Hourly disk-space reclaim — prune merged/clean worktrees, sweep orphan LastGit deploy/forge scratch, sweep orphan build processes, sweep stale build caches, and purge below the disk floor. The disk-focused subset of worktree-cleanup; does not pull repos or ship code.
---

Hourly disk-space reclaim for `<WORKSPACE>`. Runs unattended every hour — make
safe choices, never block on questions, end with a one-paragraph report of what
was reclaimed and current free space (`df -h`).

This is the DISK-FOCUSED subset of the `worktree-cleanup` routine: do NOT pull
repos to latest, do NOT enumerate/archive sessions, do NOT file cards. Just
reclaim disk safely.

**Known disk hog (2026-07):** unused checkouts under
`$HOME/.lastgit/{deploy-*,forge-*}/scratch` (and one-shot `scratch-once*`) plus
stale `ship-runs` / non-live `ship-checkouts` regularly grow to hundreds of GB
while agent worktrees look modest. **Always** run the LastGit scratch prune
below — not only when under the disk floor.

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
- NEVER remove a worktree with uncommitted changes
  (`git -C <wt> status --porcelain` non-empty) OR unique unmerged commits
  (`git -C <wt> cherry origin/<DEFAULT_BRANCH> <branch>` shows any `+`). Keep
  `salvage-*` / `tombstone-*` / `locked` worktrees.
- NEVER touch a worktree whose board card is in `doing`/`review`. Read the board
  first (`<board list command>`) and cross-check by intent.

## Procedure each run
0. **Normalize the scheduled shell.** Source the Last Stack PATH prelude and
   preflight the global CLIs before shell-heavy work:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   last_stack_require_tools git curl jq find rm <board-cli>
   ```
1. **Assess.** `df -h <data volume> | tail -1`; list any build/server processes
   and confirm which one is your live brain/board node so you never touch it.
2. **Discover repo roots before any repo-level Git command.** The workspace
   root may be only a container directory, so do not probe it as a checkout.
   Enumerate child repos first, then run Git against each repo:
   ```bash
   workspace="<WORKSPACE>"
   last_stack_run_tool "$LAST_STACK_TOOL_FIND" "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
     | while IFS= read -r git_dir; do
         repo="${git_dir%/.git}"
         last_stack_run_tool "$LAST_STACK_TOOL_GIT" -C "$repo" rev-parse --show-toplevel
       done
   ```
   Use those repo roots to enumerate worktrees across all repos + all worktree
   locations via `git -C "$repo" worktree list --porcelain`; derive each one's
   repo from `git -C <path> rev-parse --git-common-dir`.
3. **Per worktree, compute** branch, unique-commit count, dirty count, and
   whether a live process runs in it. A worktree is REMOVABLE only if 0 unique
   commits AND clean AND its card isn't `doing`/`review`. If it has a live orphan
   process (verify its command path is inside the worktree and it is NOT your
   node), kill that PID first, then `git worktree remove --force <path>` and
   `git branch -D <branch>`. Then `git worktree prune` per repo. Remove a now-
   empty worktree parent dir. Use `last_stack_run_tool "$LAST_STACK_TOOL_GIT"`
   and `last_stack_run_tool "$LAST_STACK_TOOL_RM"` for generated cleanup
   commands in this stripped-shell path.
3a. **Reap stale dev-server port orphans (port-scoped, brain-safe).** A preview /
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
4b. **LastGit scratch prune (ALWAYS — do this every run, not only under the
   floor).** Deploy/forge pipelines leave full checkouts under
   `$HOME/.lastgit/…/scratch`; those are the usual multi-hundred-GB hog.
   **Never delete** cursor files, `*.log`, `canary-state.json`, parent pipeline
   dirs, or `mirror-clones` / `primary` / forge data dirs themselves — only
   **unused scratch children** (and unused ship-run/checkout trees).

   **Live-path set (KEEP anything referenced):**
   ```bash
   lastgit_home="${LASTGIT_HOME:-$HOME/.lastgit}"
   live_file="$(mktemp)"
   {
     # Open files under lastgit (cwd, scripts, docker bind-mounts)
     lsof 2>/dev/null | grep -oE "${lastgit_home}/[^ ]+" || true
     # Docker container mounts (active lambda/container builds)
     if command -v docker >/dev/null 2>&1; then
       docker ps -q 2>/dev/null | while IFS= read -r id; do
         docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$id" 2>/dev/null
       done | grep -E "^${lastgit_home}/" || true
     fi
   } | sort -u > "$live_file"
   ```
   A path is **LIVE** if any live entry equals it, is under it, or it is under a
   live entry. Prefer a cheap prefix check over recursive `lsof +D` (which can
   hang the unattended window).

   **Scratch roots to scan** (create-none; skip missing):
   - `$lastgit_home/deploy-*/scratch`
   - `$lastgit_home/deploy-*/scratch-once*`  (remove the whole once-dir when not live)
   - `$lastgit_home/forge-*/scratch`
   - `$lastgit_home/ship-runs/*` (per-repo run trees)
   - `$lastgit_home/ship-checkouts/*` (only when **not** live; if live, you may
     strip only nested `.docker-cache` / `target` / `cdk/node_modules` that are
     themselves not live)

   **Remove rule:** for each child of a scratch root (or each once-dir / ship
   tree), if it is **not LIVE**, `rm -rf` it. Log `RM <path>` and `KEEP live
   <path>`. Do **not** require the disk floor — always drain unused scratch so
   deploy history cannot silently fill the volume between floor breaches.

   **Hard no-touch under `$lastgit_home`:** `primary/`, `mirror-clones/` (except
   optional nested `target/` / `.docker-cache` **only** when that path is not
   live and free space is under the floor), forge/deploy **parent** config
   (`deploy.cursor`, `*.log`, `canary-state.json`, launchd logs). Never wipe the
   entire `$HOME/.lastgit` tree.

   Record approximate size before/after (`du -sh "$lastgit_home"`) in the report.
5. **Disk floor.** If free space < `<your floor, e.g. ~30 GB>`, proactively purge
   the largest reclaimable build-cache dir with an **atomic swap** so an active
   build doesn't see a half-deleted tree: `mv target target.PURGE` → recreate an
   empty `target/` → `rm -rf target.PURGE` in the background. Stop active
   compiles first (kill the compiler processes, NOT the node). Prefer, in order:
   (1) leftover LastGit scratch still present after step 4b, (2) shared
   `target/` / sccache / act caches, (3) other regenerable agent caches. Never
   blow away a shared build cache while you're still above the floor **except**
   the always-on LastGit scratch prune in 4b.

## Output
Report: GB reclaimed, worktrees pruned (and which were kept and why), LastGit
scratch entries removed/kept-live, `du -sh $HOME/.lastgit` before/after, final
free space, and anything left for a human.
