---
name: machine-hygiene
description: |
  EdgeVector workspace health + cleanup handbook. Keep ~/code/edgevector/ healthy:
  reclaim disk, prune stale worktrees/branches, bring repos to latest main, enumerate
  stale Claude sessions, and apply the prevention upkeep that stops buildup from
  recurring. Triggered when the user (or a scheduled task) says "follow the
  machine-hygiene skill", "clean up stale worktrees", "the machine is full / wedged",
  "free up disk", or this is the `clean-up-stale-worktrees` 3 AM routine.
---

# EdgeVector machine hygiene — handbook

You are responsible for keeping this machine able to build/code: disk healthy, repos
on latest `main`, no stale artifacts, and the recurring buildup kept in check. Most
runs are **unsupervised at 3 AM** — make reasonable choices, never block on questions,
produce a report. If the user is actively chatting, you may take the supervised-only
actions noted below.

## 🛑 Hard guardrails (violating these has caused outages)

- **NEVER kill the primary `folddb_server` brain.** It's Tom's primary brain with live Chrome
  connections; long uptime is NOT an orphan signal. Identify the primary brain by its socket
  (`lsof /Users/tomtang/.folddb/data/folddb.sock`) or process (`pgrep -fl folddb_server`)
  before touching any folddb_server — the TCP port is gone, so a port probe no longer finds it.
  The **preview-port reaper (§4a)** is brain-safe by construction: it excludes any PID bound to
  the brain socket and kills only vite/`run.sh` dev launches on the preview ports — match by
  port + cmdline, never by the name "node"/"folddb".
- **NEVER stash/reset/`checkout --` in a shared repo.** Multiple agents share these
  checkouts. Use worktrees, never destroy uncommitted work.
- **NEVER touch in-progress kanban work.** Tasks in `in_progress`/`review` on the kanban
  board (and their `~/.cline/worktrees/<id>` worktrees + branches) are off-limits.
- **NEVER force-remove a worktree that has a live process in it**, and **never kill a
  `claude` agent process.** Removing a worktree out from under a live `folddb_server` has
  produced a 339 GB orphan-server wedge.
- **`archive_session` is unavailable in unsupervised mode** (it always prompts). Do not
  attempt it at 3 AM — **enumerate** stale sessions and report instead.
- **`cargo clean` / removing the shared target BREAKS live builds** — only do it after
  quiescing the agents using it (see Disk section).

## Environment facts (so you don't re-derive them)

- **Repos** live directly under `~/code/edgevector/` (fold, fold_dev_node, exemem-infra,
  schema-infra, fbrain, edgevector-website, fold_db_website, homebrew-folddb,
  exemem-workspace, edgevector-org-github, demo-repository). The umbrella `edgevector`
  dir is itself a stray git repo wrapper — leave it alone.
- **Worktrees live in FIVE places** — check all each run, and authoritatively enumerate
  via `git -C <repo> worktree list --porcelain` for fold / fbrain / fold_dev_node /
  schema-infra / exemem-infra / exemem-workspace (don't trust a single dir listing): (1)
  **fkanban worktrees** `~/.fkanban/worktrees/<slug>/` (protected if the card is
  `DOING`/`REVIEW`; `~/.cline/worktrees/` is the legacy/empty predecessor); (2) gstack
  agent worktrees `fold/.claude/worktrees/<name>` and `fold_dev_node/.claude/worktrees/<name>`
  (live idle procs → archive the session to free them; two `agent-*` ones are `locked` WIP —
  never touch); (3) **top-level sibling worktrees** `~/code/edgevector/<name>` (e.g.
  `fold-superset-tray`, `fold-aws-runtime-pin`) AND `~/code/edgevector-worktrees/<name>`
  (`app-sec/*`, `app-run/*`, plus some `exemem-workspace` doc worktrees like `nmsr-correct`);
  (4) **`~/code/edgevector/.worktrees/<name>`** — a newer internal location (e.g.
  `schema-naming-ingestion-method`). The siblings are the easiest to miss — find them via
  `git -C <path> worktree list`. NOTE: a worktree's parent dir does NOT identify its repo — derive the
  repo from `git -C <path> rev-parse --git-common-dir`. Prune any with 0 unique commits
  (`git cherry origin/main <br>` → 0) AND a clean tree; **keep ones with uncommitted WIP**
  (a clean committed branch can still carry uncommitted changes — `status --short` before
  removing). Remove the now-empty `edgevector-worktrees/` dir when its last child is gone.
  **Squash-merge caveat:** `git cherry` reports `>0` unique even for a merged branch (the
  squashed commit has a different patch-id), so DON'T read cherry>0 as "unmerged" — verify
  with `gh pr list -R <owner>/<repo> --head <br> --state all`; MERGED (or CLOSED with the remote branch still
  present → recoverable) is deletable. **exemem-infra / exemem-infra-monorepo worktrees
  contain submodules**, so `git worktree remove` fails ("working trees containing submodules
  cannot be moved or removed") — workaround: `rm -rf <worktree-dir>` then
  `git -C <repo> worktree prune` + `git branch -D <br>` (safe when clean + no live proc).
- **The disk hog is the single shared `fold/target`** (and `fold_dev_node/target`). Every
  kanban worktree (`~/.cline/worktrees/<id>/fold/target`) and gstack worktree
  (`fold/.claude/worktrees/<name>`) **symlinks into it**. Cargo never GCs it, so it grows
  to hundreds of GB (294 GB observed). Per-worktree targets are tiny — don't chase them.
- **The clutter engine = 4 ENABLED hourly scheduled tasks** that spawn a session (and for
  two of them a fresh `.claude` worktree) every hour and never tear down: `dog-food` (:05),
  `fold-dev-node` (:01), `fbrain-dogfooding` (:02), `check-if-kanban-tasks-are-stuck` (:07).
  Over a day → ~30 worktrees, 100+ sessions, ~33 idle resident `claude` processes.
- The dogfood `claude/*` worktrees are **data-clean** (0 commits ahead, no uncommitted
  changes) — nothing is lost by archiving them. `locked` worktrees (e.g.
  `tombstone-foundation-v2`) DO hold WIP — never touch.
- **Shell gotchas (scheduled/sandboxed Bash):** (1) destructive commands (`rm`,
  `git worktree remove`, `git branch -D`) run with a STRIPPED `$PATH` — pass
  `dangerouslyDisableSandbox: true` AND prepend an explicit PATH
  (`export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin`).
  (2) Even then, wrapping commands in a **zsh function loses PATH inside the function body**
  (`command not found: git/rm`) — INLINE the commands, don't define helper functions.

## Procedure

### 1. Assess
```bash
df -h /System/Volumes/Data | tail -1                       # free space
ps aux | grep folddb_server | grep -v grep                 # confirm primary brain only
lsof /Users/tomtang/.folddb/data/folddb.sock 2>/dev/null   # identify the primary brain by its socket
```
Read the kanban board to learn what's protected (Cline kanban is DEPRECATED — the active
board is **fkanban**): `cd ~/code/edgevector/fkanban && bun src/cli.ts list`. Protect any
card in `DOING`/`REVIEW` (and their `~/.fkanban/worktrees/<slug>` worktrees + branches).
Card slugs don't always string-match the worktree dir/branch name — cross-check by intent
(e.g. REVIEW card `app-iso-schema-infra-dev-deploy` ↔ worktree `schema-infra-app-iso-dev-deploy`
on branch `app-iso/dev-deploy-code-signature`). `~/.cline/worktrees/` is now empty/legacy.

### 2. Git hygiene (safe, always do)
For each real repo (skip the umbrella, skip dirty repos for the pull step):
```bash
git -C "$d" fetch --all --prune --quiet
# if on main and clean:
git -C "$d" pull --ff-only --quiet
git -C "$d" worktree prune
```
**Delete merged branches** — use patch-id, not `--merged` (squash merges aren't ancestors):
```bash
uniq=$(git -C "$d" cherry origin/main "$br" | grep -c '^+')   # 0 ⇒ content already in main
# delete if uniq==0 OR upstream is [gone]; use -D (squash merges need force);
# KEEP salvage-*/tombstone-* and anything with unique unpushed commits.
# Branches checked out in a live worktree are auto-protected (git refuses).
```

### 3. Disk reclaim (the shared target)
Only when free space is low. **`cargo clean` requires quiescing the agents building into
the shared target first.** If unsupervised and agents are actively building, surface it in
the report rather than breaking them — UNLESS the disk is critically full (then act).

**Atomic-swap reclaim (works even under live agents, supervised + authorized):**
```bash
# 1. stop active compiles (NOT the primary folddb_server brain, NOT node/kanban)
pkill -9 -f clippy-driver; pkill -9 -f '/rustc'; pkill -9 -f cargo
# 2. O(1) rename — zero race window — then recreate empty so worktree symlinks resolve
mv ~/code/edgevector/fold/target ~/code/edgevector/fold/target.PURGE
mkdir ~/code/edgevector/fold/target
# 3. delete the bloat off to the side (slow; run in background)
rm -rf ~/code/edgevector/fold/target.PURGE &
```
Removing `target/` only deletes build artifacts — **never source or uncommitted work** —
so agents just rebuild clean (a full fold build is ~40 GB; the rest was stale cruft).
A plain in-place `rm` races with relaunched builds for minutes and barely reclaims; the
`mv`-swap is what makes it work. Recreate `fold_dev_node/target` the same way if removed.

**0-byte deadlock:** at literally 0 bytes free, the Bash tool itself can't run (it can't
create its `/private/tmp/.../*.output` file → `ENOSPC`). Break it by freeing a few GB
first: `rm -rf ~/code/edgevector/fold_dev_node/target` (≈36 GB) ± `pkill -9 -f
'clippy-driver|rustc|cargo'`. If you can't run any command, ask the user to run that one
line.

### 4. Stale worktrees, sessions, processes
- Prune `.claude/worktrees/*` only if **no live process** (`lsof -d cwd | grep <path>`) and
  the branch is merged/clean. In practice the dogfood ones all have live idle processes, so
  the clean way to remove a worktree + stop its process is to **archive its session**.
- **Unsupervised:** you CAN'T archive. Enumerate via `mcp__ccd_session_mgmt__list_sessions`
  (stale = `isRunning:false` + dogfood title / merged branch / removed-worktree cwd) and
  list them for a UI bulk-archive. Titles to sweep: "Dog food", "Fold dev node",
  "Fbrain dogfooding", "Check if kanban tasks are stuck". KEEP the user's manual
  exploratory sessions.

### 4a. Stale preview-port orphans (port-scoped reaper — never the brain)
A force-quit preview/dev session can leave its `node` (vite / `run.sh` dev) proc
holding a preview port, so the next `preview_start` fails with
`Port 5173/5183 is in use by "node" (PID …) (not a preview server)` and the agent
stalls. Reap ONLY those orphans, keyed on **port + command line** — NEVER on the
name "node" or "folddb" (the primary brain is also a long-lived proc; uptime is
not an orphan signal). Known preview ports: **5173** (lastdb-ui), **5178**,
**5183** (newuser-node), **8766**.

```bash
# Identify the primary brain FIRST so it can never be a kill target:
brain_pids=$(lsof -t /Users/tomtang/.folddb/data/folddb.sock 2>/dev/null)
for port in 5173 5178 5183 8766; do
  for pid in $(lsof -ti :"$port" 2>/dev/null); do
    case " $brain_pids " in *" $pid "*) continue ;; esac   # never the brain socket
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    # Reap only a vite / folddb dev-server run.sh launch on a preview port:
    case "$cmd" in
      *vite*|*run.sh*|*node_modules/.bin/vite*|*newuser-node*|*lastdb-ui*)
        echo "reaping orphan preview-port proc: pid=$pid port=$port :: $cmd"
        kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null ;;
      *)
        echo "SPARED on :$port (not a preview/vite launch): pid=$pid :: $cmd" ;;
    esac
  done
done
```

Guardrails: skip any PID in `brain_pids` (the `~/.folddb/data/folddb.sock` brain),
skip a port whose owning session is still live or whose cwd is a `DOING`/`REVIEW`
fkanban worktree, and log every PID + port + cmdline reaped (and every one spared
and why). After reaping, a fresh `preview_start name=lastdb-ui` should bind
cleanly while the primary `folddb_server` brain (socket still live) is untouched.

### 5. Prevention upkeep (do this so the buildup stops recurring)
- **`cargo-sweep`** to keep the shared target bounded without nuking warm builds.
  NOTE: modern cargo-sweep uses a `sweep` SUBCOMMAND (the old top-level
  `cargo sweep --time` form errors with "unexpected argument '--time'"):
  ```bash
  command -v cargo-sweep >/dev/null || cargo install cargo-sweep   # needs ~/.cargo/bin on PATH
  cargo-sweep sweep --time 7    ~/code/edgevector/fold ~/code/edgevector/fold_dev_node
  cargo-sweep sweep --installed ~/code/edgevector/fold ~/code/edgevector/fold_dev_node
  ```
  If it "Cleaned nothing", the target is warm (all artifacts <7 days = active dev),
  not stale — that's healthy, not a failure.
- **`CARGO_INCREMENTAL=0`** in the agent/scheduled-task build env — incremental dirs are
  the bulk of target bloat and useless for one-shot agent builds. Verify it's set; if not,
  recommend wiring it into the kanban/scheduled-task env (don't silently change global env
  unattended — surface it).
- **Disk floor:** if free space < ~30 GB, run the §3 atomic-swap purge proactively instead
  of waiting for 0 bytes.
- **Concurrency:** ≥3 fold agents building into the shared target serialize on its lock and
  pile on disk — note it if you see >2 running; more agents drain the board *slower*.
- The 4 hourly dogfood tasks regenerate the clutter; if it's recurring too fast, recommend
  running them in-place (no per-run worktree) or lowering cadence — but only **change
  schedules if the user has approved it**.

## Output
End with a report: what was reclaimed/pruned, current `df -h` free space, repo states,
the safe-to-archive session list, anything left for the user (supervised-only actions,
in-progress kanban work you protected), and any prevention upkeep applied or recommended.
Update relevant memory (`project_disk_shared_fold_target`,
`feedback_scheduled_cleanup_cannot_archive_sessions`) with anything new you learned.
