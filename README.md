# The Last Stack

**The Last Stack** is a small, curated set of **agent skills** for driving a
LastDB-backed workflow with an AI coding agent — the agent layer that sits on
top of [LastDB](https://folddb.com) and its two companion tools:

- **Brain** — [`fbrain`](https://github.com/EdgeVector/fbrain): long-lived notes
  over LastDB (the *why*: decisions, designs, milestones).
- **Kanban** — [`fkanban`](https://github.com/EdgeVector/fkanban): a task board
  over LastDB (the *what's in flight*: cards moving through columns).

These skills are written for agent harnesses that load
[Agent Skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
(a `SKILL.md` per skill, discovered by the agent and invoked by name) — e.g.
Claude Code. They give an agent a consistent playbook for filing tasks, driving
a single task to a merged pull request, waiting on PRs robustly, and closing out
finished work.

## What's in the stack

| Skill | What it does |
|---|---|
| **fkanban** | Board CRUD over LastDB — file/list/show/move/groom cards. |
| **fkanban-agent** | Drive a single card all the way to a **merged** PR; or reconcile-sweep an in-flight board. |
| **fkanban-setup** | Bootstrap fkanban on a fresh machine — install, `init` (resolve published schemas), `doctor`, optional MCP registration. |
| **wait-merge** | Robustly wait for a GitHub PR to merge by interpreting PR *state*, not a watcher's exit code. |
| **close-out** | The post-change loop: open a PR from a worktree, drive it to merged, checkpoint the decision to the brain, file a follow-up card. |

## Install

Skills are plain directories — drop them where your agent looks for skills. For
Claude Code, that's `~/.claude/skills/` (user-level) or `.claude/skills/`
(project-level):

```bash
# clone the stack
git clone <this-repo-url> last-stack

# install all skills at the user level
mkdir -p ~/.claude/skills
cp -R last-stack/skills/* ~/.claude/skills/
```

Each skill is self-contained — copy only the ones you want. After installing,
your agent discovers them by name (e.g. "follow the fkanban-agent skill",
"set up fkanban", "wait for this PR to merge").

You'll also want the underlying tools installed and a LastDB node running — see
the **fkanban-setup** skill and the `fkanban` / `fbrain` repos.

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

## Configuring the node URL

Every skill talks to a LastDB node over HTTP. The node URL is **configurable** —
`fkanban init` defaults to a node running locally on your machine, and you
override it with `--node-url` (and `--schema-service-url` for a different schema
service). Point the skills at whichever node hosts your board and brain.

## License

MIT — see [LICENSE](LICENSE).
