# The Last Stack

**The Last Stack** is a small, curated set of **agent skills** for driving a
LastDB-backed workflow with an AI coding agent — the agent layer that sits on
top of [LastDB](https://folddb.com) and its two companion tools:

- **Brain** — [`fbrain`](https://github.com/EdgeVector/fbrain): long-lived notes
  over LastDB (the *why*: decisions, designs, milestones).
- **Kanban** — [`fkanban`](https://github.com/EdgeVector/fkanban): a task board
  over LastDB (the *what's in flight*: cards moving through columns).

The skills are written for agent harnesses that load
[Agent Skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
(a `SKILL.md` per skill, discovered by the agent and invoked by name) — e.g.
Claude Code, Codex, Factory, OpenCode. They give an agent a consistent playbook
for filing tasks, driving a single task to a merged pull request, waiting on PRs
robustly, and closing out finished work.

The companion **routines** (`routines/`) are the *engine* that runs the playbook
on a schedule: small, parameterized prompts you register as scheduled (cron)
agents — a self-improvement loop, papercut sweep, machine-hygiene/disk-reclaim, a
PR drainer, and the kanban/brain driving loop (pickup, watch, groom,
program-driver, rollup, consolidate, morning-sync). The skills *assume* this
pipeline exists; the routines provide it. See
[`routines/README.md`](routines/README.md).

## Install

One line — clone the repo and run `setup`:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack && ~/.last-stack/setup
```

`setup` auto-detects which agent harnesses you have (Claude Code, Codex,
Factory, OpenCode) and registers every skill into each one. The skills stay in
the cloned repo; each harness gets a directory with a symlinked `SKILL.md`, so a
later `git pull` updates every installed skill at once.

For Claude Code, `setup` also installs the bundled safety hooks and allowlists
the `fbrain` MCP read tools plus `fbrain_put` in `~/.claude/settings.json`, so
scheduled routines can use the brain tools without unattended permission
declines.

Options:

```bash
~/.last-stack/setup --host claude   # install for one harness only
~/.last-stack/setup --local         # vendor into ./.claude/skills (this project only)
~/.last-stack/setup --uninstall     # remove the registered skills
```

## Download LastDB + Apps

To download the usable LastDB app stack in one pass, run:

```bash
~/.last-stack/bin/last-stack-install-apps
```

That installs the LastDB daemon and downloads Brain, Kanban, Situations, Dogfood
Graph, and LastSecrets. LastGit is intentionally excluded until it is stable
enough for the public bundle. See
[`docs/lastdb-apps.md`](docs/lastdb-apps.md) for the full guide.

> Prefer to copy skills by hand? Each skill is a self-contained directory under
> `skills/` — `cp -R skills/<name> ~/.claude/skills/`. `setup` just automates that
> across every harness and keeps them updatable.

## Upgrade

```bash
cd ~/.last-stack && git pull && ./setup
```

Or just tell your agent **"upgrade the last stack"** — the included
**last-stack-upgrade** skill does the pull + re-register and shows what changed.
Skills can cheaply check for a new version via `bin/last-stack-update-check`
(cached, never blocks; prints `UP_TO_DATE` / `UPGRADE_AVAILABLE` / `UNKNOWN`).

> **Run `setup` AFTER any gstack setup / `/gstack-upgrade`.** gstack `./setup`
> re-symlinks its own skills into `~/.claude/skills/<name>`; when a gstack skill
> shares a name with a Last Stack one (e.g. gstack's mermaid `diagram` vs. the
> hand-drawn architectural `/diagram`) it silently replaces ours. Last Stack
> `setup` re-points our links and finishes by running
> `bin/last-stack-verify-skill-links`, which verifies every Last Stack skill still
> resolves into the Last Stack tree and repairs any that a foreign installer
> stomped. Run that guard standalone any time to check (`--check`) or repair.

## Keeping The Last Stack Current

Treat reusable agent improvements as upstream candidates by default. When a
session produces a new skill, routine, permission pattern, or process rule,
first decide whether it is workspace-specific or generally useful. If it is
portable, make the change safe for this repo and upstream it here so every
installed harness can pick it up on the next `git pull && ./setup`.

The expected path is:

1. Capture the rationale in the brain (`fbrain`) when the change should survive
   the current chat.
2. File or update a board card (`fkanban`) for the delivery/audit trail.
3. Patch the shared skill or routine in `skills/` or `routines/` using
   placeholder-based, product-neutral wording.
4. Verify the changed prompt still works cold, without chat memory or local-only
   assumptions.
5. Leave workspace-only details in the workspace's own agent docs, not in this
   pack.

This keeps one-off local improvements from quietly forking the fleet while still
preserving project-specific rules where they belong.

## What's in the stack

| Skill | What it does |
|---|---|
| **fkanban** | Board CRUD over LastDB — file/list/show/move/groom cards. |
| **fkanban-agent** | Drive a card to **merged**, reconcile in-flight PRs, or validate post-merge END STATE checks. |
| **fkanban-setup** | Bootstrap fkanban on a fresh machine — install, `init` (resolve published schemas), `doctor`, optional MCP registration. |
| **onecontext** | Search prior Codex sessions, with guarded Aline usage and a JSONL fallback when Aline is unavailable. |
| **wait-merge** | Robustly wait for a GitHub PR to merge by interpreting PR *state*, not a watcher's exit code. |
| **close-out** | The post-change loop: open a PR from a worktree, drive it to merged, checkpoint the decision to the brain, file a follow-up card. |
| **last-stack-upgrade** | Update the stack in place and re-register the skills. |
| **session-miner** | Generic engine for mining recent agent session transcripts with profiles for papercuts, incidents, owner-stated knowledge, and tooling friction. |

And the **routines** (`routines/`) — parameterized scheduled-agent templates that
run the skills on a cadence:

| Routine | What it does |
|---|---|
| **self-improvement-loop** | Mine recent sessions for friction; upgrade the agent's own skills/routines/permissions. |
| **papercut-sweep** | File a card per dev-process papercut found in sessions. |
| **devops-continuous-improvement** | Inspect CI, merge flow, deployment, testing, and release gates; ship one small DevOps fix or file precise cards. |
| **worktree-cleanup** / **disk-reclaim** | Prune stale worktrees/branches; reclaim disk; keep the machine healthy. |
| **drain-open-prs** | Drive every open PR across all repos toward zero (merge or close). |
| **fkanban-pickup** / **fkanban-watch** / **fkanban-validate** | Drain the ready queue; reconcile PRs; run post-merge END STATE validation. |
| **groom-board** / **program-driver** | Promote ready work into `todo`; keep each program's next card flowing. |
| **program-rollup** / **consolidate-brain** / **morning-sync** | Mirror the board into the brain; keep statuses honest; deliver the daily decision briefing. |

See [`routines/README.md`](routines/README.md) for how routines + skills compose,
and fill in the `<PLACEHOLDERS>` before scheduling any of them.
For a new project, start with the routine fleet bootstrap guide and record
templates in [`docs/routine-fleet-portability.md`](docs/routine-fleet-portability.md)
and [`templates/routine-fleet/`](templates/routine-fleet/).

## Repo layout

```
VERSION                 the installed version (update-check compares against this)
setup                   installer — registers skills into your agent harnesses
bin/
  last-stack-update-check   is a newer version or default-branch HEAD available?
                            (version checks cached; git HEAD checks uncached)
  last-stack-verify-skill-links
                            verify (and by default repair) that every Last Stack
                            skill link still resolves into the Last Stack tree;
                            undoes a gstack same-name skill stomp. setup runs it
                            as its final step. --check reports only.
  last-stack-shell-prelude  sourceable PATH prelude for scheduled routines
  last-stack-cli-preflight  verify routine-required global CLIs are on PATH
  last-stack-json-get       extract one simple field path from socket/API JSON
                            without relying on jq or inline python/node parsing
  last-stack-repo-op-guard  reject workspace roots before repo-scoped git/gh
  last-stack-pr-venue       route a repo to github, forgejo, or explicit
                            LastGit-native CR handling before PR/CR operations
  last-stack-gh-pr-queue-state
                            GraphQL PR queue-state helper without gh -R drift
  last-stack-forge-ci-log   print a failing forge (Forgejo) CI job's log tail —
                            resolves the run + attempt-scoped web log endpoint
                            (run with dangerouslyDisableSandbox: TCP to :3300 is
                            sandbox-blocked)
  last-stack-forge-json-jq   control-char-safe jq wrapper for Forgejo API JSON
                            status polls
  last-stack-routine-read   freshness/missing-file guarded routine prompt reader
  last-stack-dogfood-target-checkout
                            select a current dogfood checkout without mutating
                            the recipe's original target checkout
  last-stack-git-checkout-freshness
                            non-mutating tracked-remote freshness preflight
  last-stack-fbrain-append-heartbeat
                            safely add a typed routine-heartbeats line
  last-stack-active-programs-guard
                            reject active-programs rewrites that drop program
                            headers/slugs; split closed programs into archive
  last-stack-install-apps   download LastDB plus the usable app stack
  last-stack-uninstall      remove the registered skills
skills/<name>/SKILL.md  one directory per skill
instructions/brain-kanban.md
                        canonical fbrain/fkanban usage guidance; setup upserts it
                        as a managed block into each harness's global AGENTS.md
                        and registers the fbrain/fkanban MCP servers for Codex
                        (with a PATH env so GUI-spawned servers can find bun)
routines/<name>.md      one parameterized scheduled-agent template per routine
routines/README.md      how routines + skills compose; how to register them
templates/routine-fleet/
                        portable Brain record templates for project routine
                        config, probe registries, and shared SOPs
```

## How an AI agent uses this

The intended loop, end to end:

1. **File work as cards** (`fkanban` skill). A card body is the spec: a `Repo:` /
   `Base:` header plus GOAL / STEPS / VERIFY / DONE WHEN. Cards live on your
   LastDB node.
2. **Drive one card to merged** (`fkanban-agent` skill, WORK mode). The agent
   claims the card, works in an isolated git worktree, opens a PR, and then
   *drives that PR to MERGED* — re-arming auto-merge, updating a behind branch,
   rebasing conflicts — before moving the card to `done`, or to `review` with a
   `BLOCKED: awaiting <validation>` marker when the END STATE requires an async
   post-merge check. A card is only `done` when its code is actually in the repo
   and the outcome is proven.
3. **Wait on PRs without false failures** (`wait-merge` skill). Interprets PR
   state rather than trusting a watcher's exit code, so transient CI/queue churn
   doesn't look like a failure.
4. **Reconcile the board** (`fkanban-agent` skill, RECONCILE mode). A scheduled
   sweep moves merged-but-unadvanced cards to `done` and nudges stuck PRs —
   leaving un-started cards alone.
5. **Validate post-merge outcomes** (`fkanban-agent` skill, VALIDATE mode). A
   scheduled pass runs one dev-only post-merge END STATE check, then moves the
   card to `done` on pass or `review` with `PROOF:` plus a fix card/blocker on
   fail.
6. **Close out** (`close-out` skill). After any substantive change: PR from a
   worktree, drive to merged, checkpoint the *why* to the brain (`fbrain`), and
   file any follow-up as a card (`fkanban`).

The two halves are deliberate: **the brain records why; the board records
what's in flight.** Keep decisions in `fbrain` and active work in `fkanban`, and
the agent always has both context and a worklist.

Steps 1–6 describe what an agent does *when invoked*. To make the loop
**self-driving** — so cards get filed, promoted, picked up, and reconciled
without a human kicking it each time — register the **routines** as scheduled
agents: generators (`self-improvement-loop`, `papercut-sweep`) file work,
`groom-board`/`program-driver` promote it, `fkanban-pickup` fans out WORK agents,
`fkanban-watch`/`drain-open-prs` reconcile the stragglers, `fkanban-validate`
runs post-merge END STATE checks, and
`program-rollup`/`consolidate-brain`/`morning-sync` keep the brain honest and
surface the short genuinely-human decision set. See
[`routines/README.md`](routines/README.md).

The **session-miner** skill is the shared engine behind transcript-mining
routines. A scheduled task can become a thin trigger that passes a profile name
such as `papercuts`, `incidents`, `owner-statements`, or `friction-patterns` plus
a time window; the skill handles transcript parsing, dedupe, report-only dry
runs, and profile-specific writes.

You'll also want the underlying tools installed and a LastDB node running — see
the **fkanban-setup** skill and the `fkanban` / `fbrain` repos.

## Configuring the node URL

Every skill talks to a LastDB node over HTTP. The node URL is **configurable** —
`fkanban init` defaults to a node running locally on your machine, and you
override it with `--node-url` (and `--schema-service-url` for a different schema
service). Point the skills at whichever node hosts your board and brain.

## License

MIT — see [LICENSE](LICENSE).
