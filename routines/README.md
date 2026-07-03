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
                 ┌──────────────────── the board (fkanban) ─────────────────┐
                 │  backlog → todo → doing → review → done                   │
   program-driver ─▶ promote each program's next card into `todo`           │
   groom-board    ─▶ promote ready backlog→todo, break up epics, prune junk  │
                 └──────────────────────────────────────────────────────────┘
                          │ (ready `todo` cards)
                          ▼
   fkanban-pickup ─▶ fan out one `fkanban-agent` (WORK mode) per card/batch ──▶ opens PR, drives to MERGED
                          │
                          ▼
   fkanban-watch  ─▶ RECONCILE: advance merged PRs to `done`, re-arm/un-stick the stragglers
   drain-open-prs ─▶ daily backstop: drive every open PR across all repos toward zero

                 ┌──────────────────── the brain (fbrain) ──────────────────┐
   program-rollup   ─▶ mirror board status into the driving index (auto block)
   consolidate-brain ─▶ fix lying statuses, archive completed/dupe records
   morning-sync      ─▶ surface the SHORT genuinely-human decision set
                 └──────────────────────────────────────────────────────────┘

                 ┌──────────────────── machine health ──────────────────────┐
   worktree-cleanup ─▶ prune stale worktrees/branches, bring repos to latest
   disk-reclaim     ─▶ hourly: reclaim disk, prune merged worktrees
                 └──────────────────────────────────────────────────────────┘
```

The division of labour is deliberate:

- **The board (`fkanban`) records what's in flight.** Cards move through
  columns; a card is `done` only when its PR is merged.
- **The brain (`fbrain`) records why.** Decisions, designs, the program DAGs, the
  driving index. Routines keep the brain honest against the board.
- **Generators fill the queue; the pickup engine drains it; the reconciler and
  drainer clean up the stragglers.** No single routine does everything — each is
  cheap, bounded, and exits, so several can run concurrently without wedging.

The skills assume this pipeline exists. `fkanban-agent`'s RECONCILE mode is run
*by* `fkanban-watch`; its WORK mode is fanned out *by* `fkanban-pickup`; the cards
it works are promoted *by* `program-driver` / `groom-board` and filed *by* the
generators. **Ship the skills without the routines and the playbook has no
engine.** That's why this pack exists.

## The two clusters

### A. Self-fixing fleet health — portable to any agent fleet

| Routine | Cadence (suggested) | What it does |
|---|---|---|
| [`self-improvement-loop`](self-improvement-loop.md) | daily | Mine recent agent sessions for recurring friction; upgrade the agent's OWN skills / routines / permission allowlist / docs. The flagship self-fixing loop. |
| [`papercut-sweep`](papercut-sweep.md) | daily | File a card per dev-process papercut found in sessions (does not ship fixes itself). |
| [`devops-continuous-improvement`](devops-continuous-improvement.md) | daily | Inspect CI, merge flow, deployment, testing, and release gates; ship one small DevOps fix or file precise follow-up cards. |
| [`worktree-cleanup`](worktree-cleanup.md) | daily (off-hours) | Prune stale worktrees/branches; bring repos to latest default branch. |
| [`disk-reclaim`](disk-reclaim.md) | hourly | Reclaim disk, prune merged/clean worktrees, sweep orphan processes. |
| [`drain-open-prs`](drain-open-prs.md) | daily | Drive every open PR across all repos toward zero (merge or close). |

### B. The kanban / brain driving loop — pairs 1:1 with the skills

| Routine | Cadence (suggested) | What it does |
|---|---|---|
| [`fkanban-pickup`](fkanban-pickup.md) | hourly | Drain the ready queue; fan out one `fkanban-agent` (WORK) per card/batch. |
| [`fkanban-watch`](fkanban-watch.md) | every 10–20 min | RECONCILE the board; advance merged PRs, un-stick the strays. |
| [`groom-board`](groom-board.md) | daily | Promote ready `backlog`→`todo`, break up epics, prune junk. |
| [`program-driver`](program-driver.md) | hourly | Promote each program's next DAG card into `todo`. |
| [`program-rollup`](program-rollup.md) | hourly | Mirror the board into the brain's driving index (auto-status block). |
| [`consolidate-brain`](consolidate-brain.md) | daily | Keep brain statuses honest; archive completed/dupe records. |
| [`morning-sync`](morning-sync.md) | daily | Surface the short genuinely-human decision set; a read-only briefing. |
| [`dogfood-rotate`](dogfood-rotate.md) | hourly | Rotate through the brain-owned dogfood registry; exercise one feature on isolated/dev surfaces; file deduped papercut/blocker cards (files work only). |

## Registering a routine as a scheduled agent

These templates are harness-agnostic prompts. Register each one as a recurring
agent however your harness schedules work — for example, with Claude Code's
**scheduled tasks** (a `SKILL.md`-style prompt + a cron expression), or any cron
+ headless-agent runner. The body of each `.md` file *is* the prompt; the
frontmatter suggests a cadence. The pattern every routine follows:

1. **Run cold.** Assume no memory of prior runs — read your orientation docs
   (your workspace `CLAUDE.md` / equivalent, your memory index) at the top.
2. **Resolve automation memory safely.** Codex scheduled prompts must include
   both `Automation ID: <automation-id>` and `Automation memory:
   ${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md` after
   placeholder expansion; if the scheduler supplies an explicit
   `Automation memory:` path, use it exactly. Otherwise resolve
   `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Fail
   loudly if the result is empty or starts with `/automations/`.
3. **Do ONE bounded pass**, then **exit**. Never loop, never `sleep`-to-wait.
4. **Be idempotent and additive.** Re-running should be safe. Default to *not*
   acting when in doubt.
5. **Leave a heartbeat** (optional but recommended) so a silently-failed routine
   is visible to `morning-sync` / a health check.

Safe heartbeat append pattern:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-fbrain-append-heartbeat" --line \
  "<routine> <ISO-ts> <ok|noop|error> <summary>"
```

Use this helper instead of open-coding heartbeat read/write snippets. It reads
`fbrain get routine-heartbeats --type reference --json`, aborts on any read or
JSON error, then writes the new newest-on-top line plus the existing body back
with `fbrain put routine-heartbeats --type reference`. If a project and
reference share the `routine-heartbeats` slug, the typed read still targets the
reference; if the typed read fails, the helper performs no write.

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
find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
  | while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      git -C "$repo" rev-parse --show-toplevel
    done
```

Only after that should a routine run commands such as
`git -C "$repo" worktree list --porcelain` or `git -C "$repo" status -sb`.
This avoids a noisy first failure from treating the workspace root as a repo.
GitHub commands should be repo-qualified the same way: use `gh -R <owner>/<repo>
...` (or `--repo <owner>/<repo>`) after the card or routine has resolved the
owning repo. Do not let `gh` infer a repository from an aggregate workspace.

When generating Markdown for `fbrain put`, `fkanban add`, `gh --body`, or any
similar command, keep the body out of shell-expanded strings. Use a quoted
heredoc into a temp file, pipe stdin, or pass a body file. If the text can
contain backticks, `$()`, `$var`, globs, semicolons, or other shell
metacharacters, it must never be expanded by the shell; substitute only narrow
placeholders afterward with a controlled command such as `sed`.
Unquoted heredocs such as `<<EOF` are not allowed for these bodies; use a
single-quoted delimiter such as `<<'EOF'`.

For `fbrain put`, pass the schema explicitly (`--type reference`, `--type
project`, etc.) or include a valid `type:` in frontmatter. Do not pass
`--title`; `put` takes the title from frontmatter `title:` or the first H1.
Creation-style flags belong to `fbrain <type> new`, not `put`.

Codex automation prompt skeletons should render the same information directly:

```text
Run the Last Stack routine `<routine>`: first run `<last-stack>/bin/last-stack-update-check`; if it prints `UPGRADE_AVAILABLE` or `GIT_UPDATE_AVAILABLE`, run the `last-stack-upgrade` skill or stop before reading stale routine text. Then read `<last-stack>/routines/<routine>.md` fully and execute one bounded pass. Automation ID: <automation-id>. Automation memory: ${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md. Use workspace `<workspace>`, board CLI `<board-cli>`, brain CLI `<brain-cli>`, default board `<board>` (the board name is only a `--board` argument for `list` and `add`; `show`, `move`, `rm`, and rank/dep/tag verbs operate on the default board implicitly and reject `--board`), and global CLIs from PATH.
```

When a prompt needs merge-queue membership, it must use GraphQL or a helper
wrapping GraphQL. Do not request the `isInMergeQueue` field through `gh pr`
JSON output; older GitHub CLI releases reject that field.

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
- **Dev, not prod, when a design is in flight.** Do reversible work; leave the
  prod cutover for a human.
- **File, don't ship — unless you're the executor.** The generators and triage
  routines FILE cards; only `fkanban-pickup` (via `fkanban-agent`) and the
  reconcilers actually open/merge PRs. Keep the lanes separate.

## Adapting these to your stack

The templates name `fkanban` (board) and `fbrain` (brain) because that's what the
companion skills use — but **the loop is tool-agnostic.** Swap in any board CLI
with columns and any notes store; the routine logic (promote ready work, fan out
one worker per card, reconcile merged PRs, keep the brain honest) is what
matters. Wherever a template says `bun run src/cli.ts <cmd>` or `fbrain <cmd>`,
substitute your tool's command. Wherever it says `<WORKSPACE>` /
`<owner>/<repo>` / `<DEFAULT_BRANCH>` / `<BUILD+TEST commands>`, fill in yours.

## Upstreaming Routine Improvements

When a scheduled run discovers a better way to operate the agent fleet, classify
the improvement before applying it:

- **Portable:** a better prompt step, safety rail, cadence rule, verification
  habit, or skill handoff that would help other Last Stack users. Patch the
  relevant file in this repo (`routines/` or `skills/`) with placeholders instead
  of local names, then file/update the board card and record the rationale in
  `fbrain`.
- **Workspace-specific:** a local path, repo list, credential detail, product
  policy, or environment-specific command. Keep it in the workspace's agent docs
  or local scheduled-task config, and do not bake it into this pack.

Default to upstreaming the portable part and isolating the local binding. A good
routine change should run cold from a fresh install after `git pull && ./setup`,
with no hidden dependency on the session that discovered it.
