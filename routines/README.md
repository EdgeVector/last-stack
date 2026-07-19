# The Last Stack — routines

The **skills** (`../skills/`) are the agent *playbook*: how an agent files a
task, drives one card to a merged PR, waits on a PR robustly, closes out
finished work. They describe *modes* (`WORK`, `RECONCILE`) and reference a
"pickup → agent → watch" pipeline — but a skill only runs when something *invokes
it*. The **routines** here are that something: small, self-contained prompts you
register as **scheduled (cron) agents**, each of which wakes on a cadence, does
one bounded pass, and exits. Together they turn the playbook into a self-driving
loop.

> If the skills are the rules of the game, the routines are the players who
> actually show up each turn.

These are **templates**, not drop-in config. Every one carries `<PLACEHOLDERS>`
you fill in for your own workspace (paths, repo list, the CLI you use for your
brain/board, your build/test commands). Read a routine top-to-bottom and adapt it
before you schedule it. Nothing here is tied to a specific product — these are
generalized from a working agent fleet, with all workspace-specific details
stripped out.

## How routines + skills compose

```
                 ┌─────────────────── generators ───────────────────┐
   sessions ──▶  self-improvement-loop      papercut-sweep
                 (upgrades the agent's       (files a card per
                  own skills/routines)        friction it finds)
                          │                        │
                          ▼                        ▼
                 ┌──────────────────── the board (kanban) ─────────────────┐
                 │  backlog → todo → doing → review → done                   │
   program-driver ─▶ promote each program's next card into `todo`           │
   groom-board    ─▶ promote ready backlog→todo, break up epics, prune junk  │
   feature-prove  ─▶ when feature-owner slice deps are done, run product proof│
                 └──────────────────────────────────────────────────────────┘
                          │ (ready `todo` cards)
                          ▼
   kanban-pickup ─▶ claim one card; do WORK mode inline ────────────────▶ opens PR, drives to MERGED
                          │
                          ▼
   kanban-watch  ─▶ RECONCILE: advance merged PRs, re-arm/un-stick the stragglers
   kanban-validate ─▶ VALIDATE: run post-merge END STATE checks, then done/review
   pipeline-health ─▶ every ~10m: LastGit CRs + forge PRs unblocked (stuck >10m → fix)
   drain-open-prs ─▶ daily backstop: drive every open PR across all repos toward zero

                 ┌──────────────────── the brain (brain) ──────────────────┐
   program-rollup   ─▶ mirror board status into the driving index (auto block)
   north-star-rollup─▶ cards×north_star matrix into north-star-dashboard
   consolidate-brain ─▶ fix lying statuses, archive completed/dupe records
   morning-sync      ─▶ surface the SHORT genuinely-human decision set
                 └──────────────────────────────────────────────────────────┘

                 ┌──────────────────── machine health ──────────────────────┐
   self-upgrade     ─▶ keep ~/.last-stack clean-FF to origin (unblocks fleet)
   worktree-cleanup ─▶ prune stale worktrees/branches, bring repos to latest
   disk-reclaim     ─▶ hourly: reclaim disk, prune merged worktrees
                 └──────────────────────────────────────────────────────────┘
```

The division of labour is deliberate:

- **The board (`kanban`) records what's in flight.** Cards move through
  columns; a card is `done` only when its PR is merged.
- **The brain (`brain`) records why.** Decisions, designs, the program DAGs, the
  driving index. Routines keep the brain honest against the board.
- **Generators fill the queue; the pickup engine drains it; the reconciler and
  drainer clean up the stragglers.** No single routine does everything — each is
  cheap, bounded, and exits, so several can run concurrently without wedging.

The skills assume this pipeline exists. `kanban-agent`'s RECONCILE mode is run
*by* `kanban-watch`; its WORK mode is executed inline by each scheduled
`kanban-pickup` worker; the cards it works are promoted *by* `program-driver` /
`groom-board` and filed *by* the generators. **Ship the skills without the
routines and the playbook has no engine.** That's why this pack exists.

### Scaling kanban-pickup workers

`kanban-pickup` capacity comes from separate routines registry entries with
separate ids and locks, all pointing at the same no-spawn prompt. Do not add
in-process fan-out or detached agent launches to the prompt.

Use the helper to write the base worker plus w2-w6 idempotently:

```bash
last-stack-kanban-pickup-workers --workers 6 \
  --prompt-path "$HOME/.last-stack/routines/kanban-pickup.md"
ls ~/.routines/registry/last-stack-fkanban-pickup*.toml
```

The first three workers keep the established 15-minute anchors (`:00`, `:05`,
`:10`). Workers w4-w6 fill the half-step slots (`:02:30`, `:07:30`, `:12:30`),
so the fleet gets a pickup slot about every 2.5 minutes without changing the
one-card-per-fire contract.

## The two clusters

### A. Self-fixing fleet health — portable to any agent fleet

| Routine | Cadence (suggested) | What it does |
|---|---|---|
| [`llms-txt-install-smoke`](llms-txt-install-smoke.md) | daily | Isolated dogfood of https://thelastdb.com/llms.txt first-run install; file cards on RED (never touches primary LastDB). |
| [`self-improvement-loop`](self-improvement-loop.md) | daily | Mine recent agent sessions for recurring friction; upgrade the agent's OWN skills / routines / permission allowlist / docs. The flagship self-fixing loop. |
| [`papercut-sweep`](papercut-sweep.md) | daily | File a card per dev-process papercut found in sessions (does not ship fixes itself). |
| [`devops-continuous-improvement`](devops-continuous-improvement.md) | daily | Inspect CI, merge flow, deployment, testing, and release gates; ship one small DevOps fix or file precise follow-up cards. |
| [`worktree-cleanup`](worktree-cleanup.md) | daily (off-hours) | Prune stale worktrees/branches; bring repos to latest default branch. |
| [`disk-reclaim`](disk-reclaim.md) | hourly | Reclaim disk, prune merged/clean worktrees, sweep orphan processes. |
| [`self-upgrade`](self-upgrade.md) | every 1–2 hours | Clean-only fast-forward of the install checkout + `./setup` so other routines do not stall on `LAST_STACK_ROUTINE_STALE`. |
| [`pipeline-health`](pipeline-health.md) | every ~10 min | Keep LastGit CRs and forge (fold / forge-hot) PRs unblocked; investigate and fix anything stuck >10 minutes. |
| [`merge-babysit`](merge-babysit.md) | every ~15 min | Self-heal stuck LastGit CRs, completing green laggards or filing P0 merge cards without turning transient backend outages into fleet-red runs. |
| [`drain-open-prs`](drain-open-prs.md) | daily | Drive every open PR across all repos toward zero (merge or close). |

### B. The kanban / brain driving loop — pairs 1:1 with the skills

| Routine | Cadence (suggested) | What it does |
|---|---|---|
| [`kanban-pickup`](kanban-pickup.md) | every 5m fleet slot, scalable with separate workers | Drain the ready queue; claim one card and run WORK mode inline. |
| [`kanban-watch`](kanban-watch.md) | every 10–20 min | RECONCILE the board; advance merged PRs, un-stick the strays. |
| [`kanban-validate`](kanban-validate.md) | hourly, offset from watch | VALIDATE one merged card's post-merge END STATE; move it to `done` on pass or `review` with proof/fix/blocker on fail. |
| [`groom-board`](groom-board.md) | daily | Promote ready `backlog`→`todo`, break up epics, prune junk. |
| [`program-driver`](program-driver.md) | hourly | Promote each program's next DAG card into `todo` (includes Feature Ship Loop frontier budget). |
| [`feature-prove`](feature-prove.md) | hourly | Product-proof stage for `feature-owner` cards; PASS file or fix-forward / open-decisions. |
| [`program-rollup`](program-rollup.md) | hourly | Mirror the board into the brain's driving index (auto-status block). |
| [`north-star-rollup`](north-star-rollup.md) | hourly | Roll up cards by `north_star` × column into brain `north-star-dashboard` + local HTML. |
| [`north-star-hygiene`](north-star-hygiene.md) | daily | Create missing brain North Star projects for orphan card `north_star` fields; clear high-confidence mis-tags; refresh dashboard. |
| [`consolidate-brain`](consolidate-brain.md) | daily | Keep brain statuses honest; archive completed/dupe records. |
| [`morning-sync`](morning-sync.md) | daily | Surface the short genuinely-human decision set; a read-only briefing. |
| [`sentry-triage`](sentry-triage.md) | daily | Pull unresolved issues from every configured Sentry project, dedupe, and file actionable fix cards. |
| [`dogfood-rotate`](dogfood-rotate.md) | hourly | Rotate through the brain-owned dogfood registry; exercise one feature on isolated/dev surfaces; file deduped papercut/blocker cards (files work only). |

## Registering a routine as a scheduled agent

These templates are harness-agnostic prompts. Register each one as a recurring
agent however your harness schedules work — for example, with Claude Code's
**scheduled tasks** (a `SKILL.md`-style prompt + a cron expression), or any cron
+ headless-agent runner. The body of each `.md` file *is* the prompt; the
frontmatter suggests a cadence. The pattern every routine follows:

1. **Run cold.** Assume no memory of prior runs — read your orientation docs
   (your workspace `CLAUDE.md` / equivalent, your memory index) at the top.
2. **Normalize the global CLI PATH once, then preflight required tools.**
   Scheduled shells often start with a stripped PATH; every routine should begin
   with the same global path prefix and a single up-front diagnostic instead of
   cascading `command not found` failures:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   "$last_stack/bin/last-stack-cli-preflight" git curl jq gh
   ```
   Add routine-specific CLIs such as `brain` or `kanban` to the preflight when
   the prompt needs them.
   For shell-heavy snippets or generated loops, resolve tools in the current
   shell and use the exported absolute paths instead of relying on later PATH
   lookups:
   ```bash
   last_stack_require_tools git awk basename rm bash
   "$LAST_STACK_TOOL_GIT" -C "$repo" status --short --branch
   "$LAST_STACK_TOOL_AWK" 'BEGIN { print "ok" }'
   ```
   If a resolved command is a shell script or shim with an `/usr/bin/env`
   shebang, run it through `last_stack_run_tool` inside generated snippets. This
   keeps the restored prelude PATH visible even if the surrounding snippet later
   narrows `PATH`:
   ```bash
   last_stack_require_tools fkanban
   PATH="/some/intentionally/narrow/path"
   last_stack_run_tool "$LAST_STACK_TOOL_FKANBAN" list --column doing --json
   ```
   For local Forgejo API calls, prefer
   `"$last_stack/bin/last-stack-forge-api" ...` over hand-written
   `TOKEN=$(security ...) curl ...` snippets; for Forgejo git auth failures,
   prefer `"$last_stack/bin/last-stack-forge-git" -C <repo> <git-args...>` over
   hand-built `http.<scope>.extraHeader` commands.
3. **Resolve automation memory safely.** Codex scheduled prompts must include
   both `Automation ID: <automation-id>` and `Automation memory:
   ${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md` after
   placeholder expansion; if the scheduler supplies an explicit
   `Automation memory:` path, use it exactly. Otherwise resolve
   `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Fail
   loudly if the result is empty or starts with `/automations/`.
4. **Read routine prompts through the guarded reader.** Do not `sed`/`cat`
   `routines/<routine>.md` directly. Use `last-stack-routine-read` so missing
   files and stale installed checkouts produce one actionable error:
   ```bash
   "$last_stack/bin/last-stack-routine-read" "<routine>" >/tmp/last-stack-routine.md
   ```
   On staleness the reader **auto-heals when the install tree is clean**: it
   runs `last-stack-self-upgrade` (fast-forward + `./setup`), then re-checks.
   If another process is already self-upgrading the install, it prints
   `LAST_STACK_ROUTINE_DEFERRED self_upgrade_lock` and exits 75 — treat this as
   a bounded noop/backoff, not a routine error or product blocker. If
   self-upgrade could not fetch the remote and the install remains stale, it
   prints `LAST_STACK_ROUTINE_DEFERRED self_upgrade_fetch_failed` and exits 75;
   treat it as the same bounded noop/backoff. If the install is dirty,
   diverged, or the helper is missing, it prints
   `LAST_STACK_ROUTINE_STALE` and exits 78 — stop before executing stale text.
   Do **not** set `LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1` or
   `LASTSTACK_SELF_UPGRADE_SKIP=1` in scheduled automations. Develop in a
   separate clone or worktree. If tracked dirt in the disposable install blocks
   routine-read, self-upgrade, or host-track, authorized remediation is
   backup-branch plus `git reset --hard lastgit/main` per
   `[[preference-agents-work-in-worktrees-install-checkout-disposable]]`.
   Manual fallback: `"$last_stack/bin/last-stack-self-upgrade"` or
   `cd "$last_stack" && git pull --ff-only && ./setup`.
5. **Budget LastDB reads.** Start with the narrowest data-plane read that proves
   the node is reachable, such as `<board-cli> list --column todo --json` or a
   targeted `<brain-cli> get <slug> --type <type> --json`. Prefer column/capped
   previews plus `<board-cli> show <slug> --json` for selected cards. Sequence
   Brain and board reads instead of launching broad reads concurrently, and do
   not use `doctor`/`init`/raw TCP probes as routine health gates.
6. **Do ONE bounded pass**, then **exit**. Never loop, never `sleep`-to-wait.
7. **Be idempotent and additive.** Re-running should be safe. Default to *not*
   acting when in doubt.
8. **Leave a heartbeat** (optional but recommended) so a silently-failed routine
   is visible to `morning-sync` / a health check.

Safe heartbeat append pattern:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "<routine> <ISO-ts> <ok|noop|error> <summary>"
```

Use this helper instead of open-coding heartbeat snippets. Heartbeats are
**filesystem-only** (not LastDB/brain) — the helper appends one line to
`~/.last-stack/logs/routine-heartbeats.log` (override with
`LAST_STACK_HEARTBEATS_FILE`). Read with `tail` or
`last-stack-heartbeats-path`. Never `brain put`/`brain append` heartbeats.

Safe memory-path shell pattern for rendered automation prompts:

```bash
automation_id="<automation-id>"
memory_path="<Automation memory path if supplied>"
if [ -z "$memory_path" ]; then
  memory_path="${CODEX_HOME:-$HOME/.codex}/automations/$automation_id/memory.md"
fi
case "$memory_path" in
  ""|/automations/*) echo "unsafe automation memory path: $memory_path" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$memory_path")"
touch "$memory_path"
```

This pattern must work with `CODEX_HOME` unset. Never construct automation
memory by appending `automations/...` directly to a possibly empty `CODEX_HOME`;
that can resolve to `/automations/...`. Prefer an explicit `Automation memory:`
path from the prompt, otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<id>/memory.md` and validate before
creating directories.

When writing shell snippets that may run under `zsh`, do not use `status` as a
temporary variable name. In `zsh`, `status` is a read-only special parameter; use
specific names such as `git_status`, `repo_status`, or `st` instead.
Do not use Bash-only `mapfile` / `readarray` in agent-facing snippets; macOS and
`zsh` sessions commonly lack them. Use a portable `while IFS= read -r ...` loop
or a short Python snippet for list handling.

When a routine starts from a workspace container (the directory that holds
your repos), discover child Git repositories before running
repo-level Git commands. The root may not be a checkout. Use a child-repo pass
like:

```bash
workspace="<WORKSPACE>"
last_stack_require_tools find git
last_stack_run_tool "$LAST_STACK_TOOL_FIND" "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
  | while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      last_stack_run_tool "$LAST_STACK_TOOL_GIT" -C "$repo" rev-parse --show-toplevel
    done
```

Only after that should a routine run commands such as
`git -C "$repo" worktree list --porcelain` or `git -C "$repo" status -sb`.
This avoids a noisy first failure from treating the workspace root as a repo.
GitHub commands should be repo-qualified the same way: use `gh -R <owner>/<repo>
...` (or `--repo <owner>/<repo>`) after the card or routine has resolved the
owning repo. Do not let `gh` infer a repository from an aggregate workspace.
For single-card workers, run the reusable guard before the first repo-scoped
operation:

```bash
workspace="/Users/tomtang/code/edgevector"   # or your rendered <WORKSPACE>
target_repo="$("$last_stack/bin/last-stack-repo-op-guard" "$target_repo" "$workspace")"
git -C "$target_repo" rev-parse --show-toplevel
```

The guard rejects the aggregate workspace root and requires a concrete child
checkout such as `/Users/tomtang/code/edgevector/last-stack`,
`/Users/tomtang/code/edgevector/fold`, or
`/Users/tomtang/code/edgevector/kanban` before `git` or repo-inferred `gh`
commands run.

When generating Markdown for `brain put`, `kanban add`, `gh --body`, or any
similar command, keep the body out of shell-expanded strings. Use a quoted
heredoc into a temp file, pipe stdin, or pass a body file. If the text can
contain backticks, `$()`, `$var`, globs, semicolons, or other shell
metacharacters, it must never be expanded by the shell; substitute only narrow
placeholders afterward with a controlled command such as `sed`.
Unquoted heredocs such as `<<EOF` are not allowed for these bodies; use a
single-quoted delimiter such as `<<'EOF'`.

For `brain put`, pass the schema explicitly (`--type reference`, `--type
project`, etc.) or include a valid `type:` in frontmatter. Do not pass
`--title`; `put` takes the title from frontmatter `title:` or the first H1.
Creation-style flags belong to `brain <type> new`, not `put`.

Codex automation prompt skeletons should render the same information directly:

```text
Run the Last Stack routine `<routine>`: set `last_stack="<last-stack>"`; source `$last_stack/bin/last-stack-shell-prelude`; run `$last_stack/bin/last-stack-cli-preflight git curl jq gh <board-cli> <brain-cli>`; then read the routine with `$last_stack/bin/last-stack-routine-read "<routine>"` and execute one bounded pass. The reader auto-upgrades a stale install via `last-stack-self-upgrade` before serving the prompt; if it prints `LAST_STACK_ROUTINE_DEFERRED self_upgrade_lock` or `LAST_STACK_ROUTINE_DEFERRED self_upgrade_fetch_failed`, stop before executing stale text and heartbeat a noop/backoff for transient self-upgrade backpressure. If it still prints `LAST_STACK_ROUTINE_STALE` (dirty/diverged install) or `LAST_STACK_ROUTINE_MISSING`, stop before executing stale/absent routine text and heartbeat the failure. Agents do product work in isolated worktrees. If tracked dirt in the disposable install blocks routine-read, self-upgrade, or host-track, authorized remediation is backup-branch plus `git reset --hard lastgit/main` per `[[preference-agents-work-in-worktrees-install-checkout-disposable]]`. Prefer a scheduled `self-upgrade` routine so the install stays current even when other jobs are idle. Automation ID: <automation-id>. Automation memory: ${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md. Use workspace `<workspace>` only as a container of child checkouts; before repo-scoped `git` or repo-inferred `gh`, resolve the child repo with `$last_stack/bin/last-stack-repo-op-guard "$target_repo" "<workspace>"` and use examples such as `git -C /Users/tomtang/code/edgevector/<repo> status -sb`, never the workspace root itself. Use board CLI `<board-cli>`, brain CLI `<brain-cli>`, default board `<board>` (the board name is only a `--board` argument for `list` and `add`; `show`, `move`, `rm`, and rank/dep/tag verbs operate on the default board implicitly and reject `--board`), and global CLIs from PATH.
```

When a prompt needs PR merge-queue membership, use
`$last_stack/bin/last-stack-gh-pr-queue-state <owner>/<repo> <pr-number>` or an
equivalent `gh api graphql` call with explicit owner/name variables. Do not
request the `isInMergeQueue` field through `gh pr` JSON output; older GitHub CLI
releases reject that field. Do not run `gh -R <repo> api graphql`; `gh api`
does not accept that repository shorthand on all installed CLI versions.

Treat `gh: Unknown JSON field` as a prompt/tooling compatibility issue. Do not
keep retrying the same command or classify it as a product failure. Prefer fields
that the installed GitHub CLI advertises, or use `gh api` / GraphQL for values
whose CLI JSON support drifts across versions. For release checks, do not request
`isLatest` through `gh release view --json`; use supported release fields such
as `tagName,isPrerelease,isDraft,publishedAt,url`, and when you need the latest
release identity query the API instead:

```bash
gh api repos/<owner>/<repo>/releases/latest --jq .tag_name
```

For workflow run or PR-check recency, do not request `isLatest` through `gh run
view`, `gh run list`, or `gh pr checks` JSON output. Use fields advertised by
the installed CLI such as `databaseId,status,conclusion,createdAt,headBranch`
for runs and `name,state,bucket` for PR checks, then select the newest relevant
run/check explicitly or query the Actions API.

## The golden rules every routine obeys

These are baked into every template below; they're the difference between a
self-driving fleet and a runaway one:

- **No `sleep`-to-wait, ever.** Wait for CI / a merge only with a *sleepless*
  foreground watcher that returns on real state change (see the `wait-merge`
  skill). A `sleep`-loop wedges the run and can cancel queued sibling calls.
- **One bounded pass per wake, then exit.** Waiting is the *gap between*
  invocations, not a loop inside one. (One historical fleet wedged at 124 idle
  agents / 19 GB swap — all from agents that looped instead of exiting.)
- **Never edit a shared checkout in place.** Use an isolated `git worktree add`.
  Never `git stash` / `reset` / `clean` a shared repo — sibling agents share it.
- **Never touch your live brain/board node destructively.** Don't kill, restart,
  or reset the process hosting your brain/board. Read through the app.
- **A locked brain is not a dead brain.** If a board/brain command returns
  `HTTP 423`, `keyring_undecryptable`, or "the node is up but cannot decrypt
  your data", stop and report `brain locked`; do not restart, run recovery loops,
  or attempt keychain/passphrase repair unattended.
- **A busy brain is not a dead brain.** If a board/brain command returns
  `service_timeout`, "node did not respond within 30000ms", or "too many
  concurrent reads", treat it as load/backpressure. Do not run doctor/restart
  loops. Prefer targeted reads, avoid broad list/search sweeps during the hot
  window, sequence expensive reads instead of running them in parallel, and retry
  only idempotent slug upserts in a bounded way.
- **Dev, not prod, when a design is in flight.** Do reversible work; leave the
  prod cutover for a human.
- **`gh` only speaks github.com.** A repo whose `origin` points at a self-hosted
  forge (Forgejo/Gitea/GitLab, often on localhost) must be driven through that
  forge's API for all PR work — check the workspace brain/AGENTS.md for the
  repo's forge SOP, and never read or act on a read-only GitHub mirror of a
  forge-hosted repo.
- **File, don't ship — unless you're the executor.** The generators and triage
  routines FILE cards; only `kanban-pickup` (via `kanban-agent`) and the
  reconcilers actually open/merge PRs. Keep the lanes separate.

## Adapting these to your stack

The templates name `kanban` (board) and `brain` (brain) because that's what the
companion skills use — but **the loop is tool-agnostic.** Swap in any board CLI
with columns and any notes store; the routine logic (promote ready work, fan out
one worker per card, reconcile merged PRs, keep the brain honest) is what
matters. Wherever a template says `bun run src/cli.ts <cmd>` or `brain <cmd>`,
substitute your tool's command. Wherever it says `<WORKSPACE>` /
`<owner>/<repo>` / `<DEFAULT_BRANCH>` / `<BUILD+TEST commands>`, fill in yours.

## Upstreaming Routine Improvements

When a scheduled run discovers a better way to operate the agent fleet, classify
the improvement before applying it:

- **Portable:** a better prompt step, safety rail, cadence rule, verification
  habit, or skill handoff that would help other Last Stack users. Patch the
  relevant file in this repo (`routines/` or `skills/`) with placeholders instead
  of local names, then file/update the board card and record the rationale in
  `brain`.
- **Workspace-specific:** a local path, repo list, credential detail, product
  policy, or environment-specific command. Keep it in the workspace's agent docs
  or local scheduled-task config, and do not bake it into this pack.

Default to upstreaming the portable part and isolating the local binding. A good
routine change should run cold from a fresh install after `git pull && ./setup`,
with no hidden dependency on the session that discovered it.
