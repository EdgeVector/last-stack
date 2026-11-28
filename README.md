# The Last Stack

No tests in EdgeVector repos (Tom, 2026-10-09). Read `instructions/no-tests.md`.
Situation: `no-tests-all-repos-20261009`. Keep syntax, lint, build, security,
and real operational checks. Remove stale test and test coverage requirements.

**The Last Stack** is a small, curated set of **agent skills** for driving a
LastDB-backed workflow with an AI coding agent — the agent layer that sits on
top of [LastDB](https://thelastdb.com) and its two companion tools:

- **Brain** — [`brain`](https://github.com/EdgeVector/brain): long-lived notes
  over LastDB (the *why*: decisions, designs, milestones).
- **Kanban** — [`kanban`](https://github.com/EdgeVector/kanban): a task board
  over LastDB (the *what's in flight*: cards moving through columns).

The skills are written for agent harnesses that load
[Agent Skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills)
(a `SKILL.md` per skill, discovered by the agent and invoked by name) — e.g.
Claude Code, Codex, Factory, OpenCode, Antigravity CLI (`agy`). They give an agent a consistent playbook
for filing tasks, driving a single task to a merged pull request, waiting on PRs
robustly, and closing out finished work.

The companion **routines** (`routines/`) are the *engine* that runs the playbook
on a schedule: small, parameterized prompts you register as scheduled (cron)
agents. The Kanban and Situations routines, skills and commands were removed on
2026-11-18 (Tom); the remaining routines cover machine hygiene, PR flow and
LastDB upkeep. See [`routines/README.md`](routines/README.md).

## Install

One line — clone the repo and run `setup`:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack && ~/.last-stack/setup
```

`setup` auto-detects which agent harnesses you have (Claude Code, Codex,
Factory, OpenCode, Antigravity CLI/`agy`) and registers every skill into each
one. Host-track last-stack `post_install` runs this with `--host auto`. The
skills stay in the cloned repo; each harness gets a directory with a
symlinked `SKILL.md`, so a later `git pull` updates every installed skill at
once. It also installs the
companion `routines` CLI automatically. Starting scheduled agent work remains
explicit: run `routines install-daemon` when you are ready to enable the fleet.

For Claude Code, `setup` also installs the bundled safety hooks and allowlists
the `brain` MCP read tools plus `brain_put` in `~/.claude/settings.json`, so
scheduled routines can use the brain tools without unattended permission
declines.

Options:

```bash
~/.last-stack/setup --host claude   # claude | codex | factory | opencode | agy | auto
~/.last-stack/setup --local         # vendor into ./.claude/skills (this project only)
~/.last-stack/setup --uninstall     # remove the registered skills
```

## Download LastDB + Apps

To download the usable LastDB app stack in one pass, run:

```bash
~/.last-stack/bin/last-stack-install-apps
```

That installs the LastDB daemon and downloads Brain, Kanban, Situations,
Routines, Dogfood Graph, Org, LastSecrets, Search, and LastDB Browser. The
`routines` CLI is linked alongside the other commands; installing its daemon is
an explicit follow-up because it starts scheduled agent work. The browser
launcher is linked as `lastdb-browser` and reads the machine's own LastDB
socket. LastGit is retired and is not in the bundle. See [`docs/lastdb-apps.md`](docs/lastdb-apps.md) for the full
guide.

> Prefer to copy skills by hand? Each skill is a self-contained directory under
> `skills/` — `cp -R skills/<name> ~/.claude/skills/`. `setup` just automates that
> across every harness and keeps them updatable.

## Upgrade

Prefer the clean-only helper (refuses a dirty install tree; never force-resets):

```bash
~/.last-stack/bin/last-stack-self-upgrade
```

Manual equivalent when the tree is clean:

```bash
cd ~/.last-stack && git pull --ff-only && ./setup
```

Or tell your agent **"upgrade the last stack"** — the included
**last-stack-upgrade** skill runs the helper and shows what changed.
Skills can cheaply check for a new version via `bin/last-stack-update-check`
(cached VERSION lookup; git HEAD checks are uncached; prints `UP_TO_DATE` /
`UPGRADE_AVAILABLE` / `GIT_UPDATE_AVAILABLE` / `UNKNOWN`).

**Scheduled fleets:** `last-stack-routine-read` auto-runs
`last-stack-self-upgrade` when the install is behind and clean, so routines do
not stay stuck on `LAST_STACK_ROUTINE_STALE`. Register the
[`self-upgrade`](routines/self-upgrade.md) routine as a 1–2h backstop. Keep
`~/.last-stack` free of local edits — develop in a portal worktree
(`./bin/wt start …`), never the install tree. **Where things live:**
[instructions/run-dev-state-board.md](instructions/run-dev-state-board.md)
(RUN / DEV / STATE / BOARD).

> **Run `setup` AFTER any gstack setup / `/gstack-upgrade`.** gstack `./setup`
> re-symlinks its own skills into `~/.claude/skills/<name>`; when a gstack skill
> shares a name with a Last Stack one (e.g. gstack's mermaid `diagram` vs. the
> hand-drawn architectural `/diagram`) it silently replaces ours. Last Stack
> `setup` re-points our links and finishes by running
> `bin/last-stack-verify-skill-links`, which verifies every Last Stack skill still
> resolves into the Last Stack tree and repairs any that a foreign installer
> stomped. Run that guard standalone any time to check (`--check`) or repair.

Brain and Routines admin tabs have dedicated hourly deliverers. See
[`docs/admin-deliverers.md`](docs/admin-deliverers.md) for install, dry-run,
RUN-home, and LaunchAgent details.

The Loom reaper runs each hour without an LLM. It uses the Host Track Loom
binary, a five-minute grace, six resume slots, and a 300-second resume timeout.
It abandons expired-lease execution husks after 48 hours. The runner prevents overlap
and writes its last result to
`~/.local/state/last-stack/loom-reaper/result.json`. Use
`last-stack-loom-reaper-install` to install or inspect the LaunchAgent.

v1 **reuses the existing kanban-consumer identity** (schema-agnostic deliver).
Mailbox poll + `openDelivery` stay on the admin consumer side (exemem-infra);
this repo only owns publish + stage/approve on Mini.

Dogfood evidence (2026-07-15, non-secret): staged + approved
`message_type=delivery_slice`, `shared=1`, schema
`last-stack/LastStackHealthSnapshot`, single record `health-latest`.

## Repository Venue

The Last Stack is homed on GitHub at `EdgeVector/last-stack` (since 2026-09-30;
LastGit is retired). Agent-authored changes go through GitHub pull requests
(`gh pr create`) with the required `ci-required` check from
`.github/workflows/ci-required.yml`, which runs `.lastgit/ci.sh` (bash -n and
the global lint passes; the repo has no tests).
Merge with `gh pr merge <n> -R EdgeVector/last-stack --auto --squash`.

The committed `.last-stack/pr-venue` marker (`github`) is what makes the shared
`last-stack-pr-venue` helper route this repo to GitHub.

## Keeping The Last Stack Current

Treat reusable agent improvements as upstream candidates by default. When a
session produces a new skill, routine, permission pattern, or process rule,
first decide whether it is workspace-specific or generally useful. If it is
portable, make the change safe for this repo and upstream it here so every
installed harness can pick it up on the next `git pull && ./setup`.

The expected path is:

1. Capture the rationale in the brain (`brain`) when the change should survive
   the current chat.
2. File or update a board card (`kanban`) for the delivery/audit trail.
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
| **onecontext** | Search prior Codex sessions, with guarded Aline usage and a JSONL fallback when Aline is unavailable. |
| **registry-rotator** | Generic engine for registry-backed scheduled routines: pick the most-overdue eligible entry, run its recipe, file cards, and stamp the registry log. |
| **wait-merge** | Robustly wait for a GitHub PR to merge by interpreting PR *state*, not a watcher's exit code. |
| **close-out** | The post-change loop: open a PR from a worktree, drive it to merged, file session papercuts, write a full brain report of what was done, update superseded brain records and stale kanban cards, file a follow-up card. |
| **fix-it** | Find and land the permanent fix: producer-side class change, residue gone, original live signal rechecked. |
| **incident-analysis** | Explain what happened with an evidence-backed Five Whys chain, clear cause layers, and mapped corrective actions. |
| **last-stack-upgrade** | Update the stack in place (clean-only self-upgrade) and re-register the skills. |
| **session-miner** | Generic engine for mining recent agent session transcripts with profiles for papercuts, incidents, owner-stated knowledge, tooling friction, and revenant-watch (settled-dead product truth reanimated; Brain-only). |

And the **routines** (`routines/`) are parameterized scheduled-agent templates that
run the skills on a cadence. The Kanban and Situations routines, skills and
commands were removed on 2026-11-18 (Tom); no routine here files or moves a card.

| Routine | What it does |
|---|---|
| **self-improvement-loop** | Mine recent sessions for friction; upgrade the agent's own skills/routines/permissions. |
| **revenant-watch** | Daily session-miner profile: flag agents reanimating settled-dead product truth (Brain-only ledger; open-work exemption). |
| **devops-continuous-improvement** | Inspect CI, merge flow, deployment, testing, and release gates; ship one small DevOps fix or file precise cards. |
| **worktree-cleanup** / **disk-reclaim** | Prune stale worktrees/branches; reclaim disk; keep the machine healthy. |
| **drain-open-prs** | Drive every open PR across all repos toward zero (merge or close). |
| **consolidate-brain** | Keep brain statuses honest. |

### Registry Rotator Records

The **registry-rotator** skill expects each project registry to be a Markdown
Brain record or Config document with one rotatable entry per heading, entry
fields for `track`, `cadence`, `recipe`, `pass =`, and `isolation`, and a single
`rotation-log:start/end` table with `feature`, `last_run`, `result`, and
`cards filed` columns. The engine reads project paths and venues from the
project's config source (`workspace-config` / `repo-venue-map` while those are
still interim brain shims), selects the eligible entry with the largest
`age / cadence` overdue ratio, dispatches that entry's recipe, files kanban
cards per `sop-routine-shared-contract`, and rewrites only the rotation-log row
for the selected entry. Scheduled tasks should be thin triggers that pass a
registry slug such as `registry=dogfood-registry` or an explicit Config
reference such as `registry=configurations://owner-review-rotate`.
`dogfood-rotate` is that shape: `bin/last-stack-dogfood-rotate-gate` selects
only entries whose start contract is met (`eligible`, `timeout_sec`,
`requires`, `command`) and skips compile / missing-binary / ineligible
recipes before any LLM turn. Scheduled fires set `gate_command` to
`last-stack-dogfood-rotate-gate --routines-dispatch` so the recipe starts
zero-LLM (no Codex `recommended_plugins` / Grok skill inventory preamble).

## Repo layout

```
VERSION                 the installed version (update-check compares against this)
setup                   installer — registers skills into your agent harnesses
bin/
  last-stack-update-check   is a newer version or default-branch HEAD available?
  last-stack-self-upgrade   clean-only FF pull + ./setup (used by routine-read)
  last-stack-routine-read   serve a routine prompt; auto-heals stale clean installs
                            (version checks cached; git HEAD checks uncached)
  last-stack-verify-skill-links
                            verify (and by default repair) that every Last Stack
                            skill link still resolves into the Last Stack tree;
                            undoes a gstack same-name skill stomp. setup runs it
                            as its final step. --check reports only.
  last-stack-shell-prelude  sourceable PATH prelude for scheduled routines
                            (also bypasses host-global sccache by default for
                            predictable parallel Cargo builds)
  last-stack-cargo          Cargo entrypoint that explicitly bypasses a
                            host-global rustc-wrapper unless opted back in
  last-stack-sccache-health report a cache that cannot pay for the wrapper it
                            costs: pinned full (state=full) or failing its
                            stores so it can never fill (state=degraded); exit
                            10 when the current shell still routes builds
                            through it
  last-stack-cli-preflight  verify routine-required global CLIs are on PATH
  last-stack-json-get       extract one simple field path from socket/API JSON
                            without relying on jq or inline python/node parsing
  last-stack-repo-op-guard  reject workspace roots before repo-scoped git/gh
  last-stack-pr-venue       route a repo to github (the default) or forgejo
                            (only EdgeVector/lastgit) before PR ops
  last-stack-gh-pr-queue-state
                            GraphQL PR queue-state helper without gh -R drift
  last-stack-forge-api      call the local Forgejo API with keychain/ env token
                            auth and optional control-char-safe jq projection
  last-stack-forge-git      run git against local Forgejo remotes with the token
                            injected as an HTTP extraHeader when needed
  last-stack-forge-json-jq   control-char-safe jq wrapper for Forgejo API JSON
                            status polls
  last-stack-routine-read   freshness/missing-file guarded routine prompt reader
  last-stack-dogfood-target-checkout
                            select a current dogfood checkout without mutating
                            the recipe's original target checkout
  last-stack-git-checkout-freshness
                            non-mutating tracked-remote freshness preflight
  last-stack-brain-append-heartbeat
                            append a fleet heartbeat line to a **filesystem**
                            log (NOT LastDB/brain). Default:
                            ~/.last-stack/logs/routine-heartbeats.log
  last-stack-heartbeats-path
                            print the heartbeats log path
  last-stack-active-programs-guard
                            reject active-programs rewrites that drop program
                            headers/slugs; split closed programs into archive
  last-stack-install-apps   download LastDB plus the usable app stack
  last-stack-lastdb-current maintain ~/.lastdb/current plus ~/.local/bin
                            lastdb/lastdbd/folddb shims; optionally rewrite a
                            LaunchAgent plist without restarting lastdbd
  last-stack-gui-app-memory-guard
                            8 GiB fail-closed kill for Activity Monitor
                            (not the deprecated LastDB desktop app; keep)
  last-stack-host-memory-sentinel
                            alert-only jetsam/swap/free-pct sentinel
  last-stack-host-memory-guards-install
                            install the two host-side LaunchAgents; never
                            touches the primary lastdbd process
  last-stack-uninstall      remove the registered skills
skills/<name>/SKILL.md  one directory per skill
instructions/lastdb.md
                        the minimal agent guide: what LastDB is and how to use
                        its current API and CLI. setup upserts it as a managed
                        block into each harness's global instructions file
                        (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
                        `~/.factory/AGENTS.md`, `~/.config/opencode/AGENTS.md`,
                        `~/.grok/AGENTS.md`, `~/.gemini/GEMINI.md`, and
                        `~/.gemini/config/GEMINI.md`), with the no-tests and
                        generated-evidence policy blocks. It replaces the
                        retired brain-kanban and lastdb-batching blocks. setup
                        no longer installs the shell-rule blocks; their files
                        stay in instructions/ for the hooks that name them
routines/<name>.md      one parameterized scheduled-agent template per routine
routines/README.md      how routines + skills compose; how to register them
templates/routine-fleet/
                        portable Brain record templates for project routine
                        config, probe registries, and shared SOPs
```

## How an AI agent uses this

1. **Learn LastDB** from `instructions/lastdb.md`, which `setup` installs into
   each agent's global instructions.
2. **Wait on PRs without false failures** (`wait-merge` skill). It reads PR
   state instead of a watcher's exit code.
3. **Close out** (`close-out` skill) after a substantive change.

When a defect keeps returning, or the user asks **what's the permanent fix**,
use the **fix-it** skill. Do not add a temporary repair at the consumer.

The card-driven loop (file a card, pick it up, reconcile the board) is gone
with Kanban.

## Configuring the node URL

Every skill talks to a LastDB node over HTTP. The node URL is **configurable** —
`kanban init` defaults to a node running locally on your machine, and you
override it with `--node-url` (and `--schema-service-url` for a different schema
service). Point the skills at whichever node hosts your board and brain.

## License

MIT — see [LICENSE](LICENSE).

See also [docs/lastdb-no-product-scan.md](docs/lastdb-no-product-scan.md).
