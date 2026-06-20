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

## Install

One line — clone the repo and run `setup`:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack && ~/.last-stack/setup
```

`setup` auto-detects which agent harnesses you have (Claude Code, Codex,
Factory, OpenCode) and registers every skill into each one. The skills stay in
the cloned repo; each harness gets a directory with a symlinked `SKILL.md`, so a
later `git pull` updates every installed skill at once.

Options:

```bash
~/.last-stack/setup --host claude   # install for one harness only
~/.last-stack/setup --local         # vendor into ./.claude/skills (this project only)
~/.last-stack/setup --uninstall     # remove the registered skills
```

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

## What's in the stack

| Skill | What it does |
|---|---|
| **fkanban** | Board CRUD over LastDB — file/list/show/move/groom cards. |
| **fkanban-agent** | Drive a single card all the way to a **merged** PR; or reconcile-sweep an in-flight board. |
| **fkanban-setup** | Bootstrap fkanban on a fresh machine — install, `init` (resolve published schemas), `doctor`, optional MCP registration. |
| **wait-merge** | Robustly wait for a GitHub PR to merge by interpreting PR *state*, not a watcher's exit code. |
| **close-out** | The post-change loop: open a PR from a worktree, drive it to merged, checkpoint the decision to the brain, file a follow-up card. |
| **last-stack-upgrade** | Update the stack in place and re-register the skills. |

## Repo layout

```
VERSION                 the installed version (update-check compares against this)
setup                   installer — registers skills into your agent harnesses
bin/
  last-stack-update-check   is a newer version available? (cached, non-blocking)
  last-stack-uninstall      remove the registered skills
skills/<name>/SKILL.md  one directory per skill
```

## How an AI agent uses this

The intended loop, end to end:

1. **File work as cards** (`fkanban` skill). A card body is the spec: a `Repo:` /
   `Base:` header plus GOAL / STEPS / VERIFY / DONE WHEN. Cards live on your
   LastDB node.
2. **Drive one card to merged** (`fkanban-agent` skill, WORK mode). The agent
   claims the card, works in an isolated git worktree, opens a PR, and then
   *drives that PR to MERGED* — re-arming auto-merge, updating a behind branch,
   rebasing conflicts — before moving the card to `done`. A card is only `done`
   when its code is actually in the repo.
3. **Wait on PRs without false failures** (`wait-merge` skill). Interprets PR
   state rather than trusting a watcher's exit code, so transient CI/queue churn
   doesn't look like a failure.
4. **Reconcile the board** (`fkanban-agent` skill, RECONCILE mode). A scheduled
   sweep moves merged-but-unadvanced cards to `done` and nudges stuck PRs —
   leaving un-started cards alone.
5. **Close out** (`close-out` skill). After any substantive change: PR from a
   worktree, drive to merged, checkpoint the *why* to the brain (`fbrain`), and
   file any follow-up as a card (`fkanban`).

The two halves are deliberate: **the brain records why; the board records
what's in flight.** Keep decisions in `fbrain` and active work in `fkanban`, and
the agent always has both context and a worklist.

You'll also want the underlying tools installed and a LastDB node running — see
the **fkanban-setup** skill and the `fkanban` / `fbrain` repos.

## Configuring the node URL

Every skill talks to a LastDB node over HTTP. The node URL is **configurable** —
`fkanban init` defaults to a node running locally on your machine, and you
override it with `--node-url` (and `--schema-service-url` for a different schema
service). Point the skills at whichever node hosts your board and brain.

## License

MIT — see [LICENSE](LICENSE).
