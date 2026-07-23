# The Last Stack

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
Claude Code, Codex, Factory, OpenCode. They give an agent a consistent playbook
for filing tasks, driving a single task to a merged pull request, waiting on PRs
robustly, and closing out finished work.

Compatibility skill names from the old fkanban naming remain installed where
they are needed for scheduled prompts: `fkanban-card-authoring` points agents at
`kanban`, and `fkanban-grooming` points agents at `kanban-grooming`. New prompts
should use the `kanban` names directly.

The companion **routines** (`routines/`) are the *engine* that runs the playbook
on a schedule: small, parameterized prompts you register as scheduled (cron)
agents. The operator model is **Generate -> Claim -> Reconcile -> Intake
friction**: generate PR-sized work, claim and ship it through pickup, reconcile
merge/proof/board state, and turn fleet friction into Brain records before it
becomes board work. The skills *assume* this pipeline exists; the routines
provide it. See [`routines/README.md`](routines/README.md) and the target fleet
cheat sheet in [`docs/routines-target-fleet.html`](docs/routines-target-fleet.html).

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
the `brain` MCP read tools plus `brain_put` in `~/.claude/settings.json`, so
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
Graph, Org, and LastSecrets. LastGit is intentionally excluded until it is
stable enough for the public bundle. See
[`docs/lastdb-apps.md`](docs/lastdb-apps.md) for the full guide.

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

## Admin health publish + deliver

Privacy-safe install health for the Exemem admin SPA (Kanban deliver path —
`delivery_slice` / `lastdb.slice.v1`). **Not** an admin SPA tab (that is a
separate `exemem-infra` card); this is the Mini **publisher + dogfood deliver**.

Payload (all non-secret):

| Field | Source |
|-------|--------|
| `version` | `VERSION` |
| `install_head_short` | install checkout `git rev-parse` |
| `self_upgrade_result` | `last-stack-self-upgrade --check-only` |
| `skill_link_status` | `last-stack-verify-skill-links --check` (`ok` / `drift` / `error`) |

```bash
# Write slim LastStackHealthSnapshot (key health-latest) on Mini:
~/.last-stack/bin/last-stack-publish-status
~/.last-stack/bin/last-stack-publish-status --json
~/.last-stack/bin/last-stack-publish-status --dry-run --json

# Stage (and optionally approve) a deliver to the admin kanban-consumer.
# Recipient keys are operational — reuse the enroll-kanban-consumer bundle;
# never commit them. Env names:
#   LAST_STACK_ADMIN_RECIPIENT_PUBKEY
#   LAST_STACK_ADMIN_MESSAGING_PUBLIC_KEY
#   LAST_STACK_ADMIN_MESSAGING_PSEUDONYM
~/.last-stack/bin/last-stack-deliver-status --dry-run --json
~/.last-stack/bin/last-stack-deliver-status            # stage only
~/.last-stack/bin/last-stack-deliver-status --approve  # stage + send
```

v1 **reuses the existing kanban-consumer identity** (schema-agnostic deliver).
Mailbox poll + `openDelivery` stay on the admin consumer side (exemem-infra);
this repo only owns publish + stage/approve on Mini.

Dogfood evidence (2026-07-15, non-secret): staged + approved
`message_type=delivery_slice`, `shared=1`, schema
`last-stack/LastStackHealthSnapshot`, single record `health-latest`.

## Repository Venue

The Last Stack is homed in LastGit at `lastdb:///last-stack`; agent-authored
changes go through LastGit change requests with the required `ci-required` gate
from `.lastgit/ci.sh`. The GitHub repository remains the public read-only clone
and browse mirror for installers and documentation links.

The committed `.last-stack/pr-venue` marker is what makes the shared
`last-stack-pr-venue` helper route this repo to LastGit. Mirror synchronization
is an operational concern of the LastGit multi-repo mirror supervisor; do not
open ordinary development PRs against the GitHub mirror.

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
| **kanban** | Board CRUD over LastDB — file/list/show/move/groom cards. |
| **kanban-agent** | Drive a card to **merged**, reconcile in-flight PRs, or validate post-merge END STATE checks. |
| **fkanban-card-authoring** | Compatibility shim for old prompts; use **kanban** for current card authoring rules. |
| **fkanban-grooming** | Compatibility shim for old prompts; use **kanban-grooming** for current board grooming rules. |
| **kanban-setup** | Bootstrap kanban on a fresh machine — install, `init` (resolve published schemas), `doctor`, optional MCP registration. |
| **onecontext** | Search prior Codex sessions, with guarded Aline usage and a JSONL fallback when Aline is unavailable. |
| **registry-rotator** | Generic engine for registry-backed scheduled routines: pick the most-overdue eligible entry, run its recipe, file cards, and stamp the registry log. |
| **wait-merge** | Robustly wait for a GitHub PR to merge by interpreting PR *state*, not a watcher's exit code. |
| **close-out** | The post-change loop: open a PR from a worktree, drive it to merged, checkpoint the decision to the brain, file a follow-up card. |
| **last-stack-upgrade** | Update the stack in place (clean-only self-upgrade) and re-register the skills. |
| **session-miner** | Generic engine for mining recent agent session transcripts with profiles for papercuts, incidents, owner-stated knowledge, and tooling friction. |

And the **routines** (`routines/`) — parameterized scheduled-agent templates that
run the skills on a cadence. Operator-facing ownership is intentionally folded:
`pipeline-health` owns merge-babysit and drain-style pipeline unblock work, while
`board-reconcile` is the single board closeout/proof surface made from
`kanban-watch`, the always-on zero-LLM closeout, `kanban-validate`, and the
reaper.

| Routine | What it does |
|---|---|
| **self-improvement-loop** | Mine recent sessions for friction; upgrade the agent's own skills/routines/permissions. |
| **papercut-reconciler** | The ONLY papercut→card path: harvest session papercuts into Brain records, cluster ALL open Brain papercuts into patterns, file pattern-level cards. |
| **devops-continuous-improvement** | Inspect CI, merge flow, deployment, testing, and release gates; ship one small DevOps fix or file precise cards. |
| **worktree-cleanup** / **disk-reclaim** | Prune stale worktrees/branches; reclaim disk; keep the machine healthy. |
| **drain-open-prs** | Drive every open PR across all repos toward zero (merge or close). |
| **kanban-pickup** / **kanban-watch** / **kanban-validate** | Drain ready **PR** queue; reconcile PRs; **proof lane** (DONE-WHEN + backlog validation proofs + post-merge END STATE). |
| **groom-board** / **north-star-driver** / **milestone-driver** | Promote ready work and turn North Star intent into milestones and PR-sized cards. |
| **program-rollup** / **consolidate-brain** / **morning-sync** | Mirror the board into the brain; keep statuses honest; deliver the daily decision briefing. |

`program-driver` is DROP/superseded: do not use it as a milestone driver and do
not add new feature-owner cards. New feature or North Star work flows through a
Brain North Star, `MILESTONE_REQUEST`, `north-star-driver`, and
`milestone-driver`.

See [`routines/README.md`](routines/README.md) for how routines + skills compose,
and fill in the `<PLACEHOLDERS>` before scheduling any of them.
For a new project, start with the routine fleet bootstrap guide and record
templates in [`docs/routine-fleet-portability.md`](docs/routine-fleet-portability.md)
and [`templates/routine-fleet/`](templates/routine-fleet/).

### Registry Rotator Records

The **registry-rotator** skill expects each project registry to be a Markdown
record with one rotatable entry per heading, entry fields for `track`,
`cadence`, `recipe`, `pass =`, and `isolation`, and a single
`rotation-log:start/end` table with `feature`, `last_run`, `result`, and
`cards filed` columns. The engine reads project paths and venues from the
project's config source (`workspace-config` / `repo-venue-map` while those are
still interim brain shims), selects the eligible entry with the largest
`age / cadence` overdue ratio, dispatches that entry's recipe, files kanban
cards per `sop-routine-shared-contract`, and rewrites only the rotation-log row
for the selected entry. Scheduled tasks should be thin triggers that pass a
registry slug such as `registry=dogfood-registry`.

## Repo layout

```
VERSION                 the installed version (update-check compares against this)
setup                   installer — registers skills into your agent harnesses
lib/
  lastdb-http.sh        shared Mini socket HTTP helpers for publish/deliver
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
  last-stack-publish-status write slim LastStackHealthSnapshot to Mini (VERSION,
                            install HEAD, self-upgrade check, skill-link verify)
  last-stack-deliver-status publish + stage/approve lastdb.slice.v1 to the admin
                            kanban-consumer (routines deliver-status pattern)
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
  last-stack-forge-api      call the local Forgejo API with keychain/ env token
                            auth and optional control-char-safe jq projection
  last-stack-forge-git      run git against local Forgejo remotes with the token
                            injected as an HTTP extraHeader when needed
  last-stack-forge-json-jq   control-char-safe jq wrapper for Forgejo API JSON
                            status polls
  last-stack-forge-runner-lanes
                            discover/verify merge-gate vs dedicated `heavy`
                            release/deploy runner capacity (see
                            docs/forge-runner-lanes.md); proof:
                            `bin/last-stack-forge-runner-lanes --check`
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
  last-stack-board-drain-report
                            print board position plus 1h/6h/24h pickup drain
                            velocity from routine-heartbeats and run metadata
  last-stack-active-programs-guard
                            reject active-programs rewrites that drop program
                            headers/slugs; split closed programs into archive
  last-stack-install-apps   download LastDB plus the usable app stack
  last-stack-lastdb-current maintain ~/.lastdb/current plus ~/.local/bin
                            lastdb/lastdbd/folddb shims; optionally rewrite a
                            LaunchAgent plist without restarting lastdbd
  last-stack-uninstall      remove the registered skills
skills/<name>/SKILL.md  one directory per skill
  (includes lastdb-safe-upgrade — multi-harness Mini safe upgrade)
instructions/brain-kanban.md
                        canonical brain/kanban usage guidance; setup upserts it
                        as a managed block into each harness's global
                        instructions file (`~/.claude/CLAUDE.md`,
                        `~/.codex/AGENTS.md`, `~/.factory/AGENTS.md`,
                        `~/.config/opencode/AGENTS.md`) and registers the
                        brain/kanban MCP servers for Codex (with a PATH env so
                        GUI-spawned servers can find bun); also records the
                        creation-time default that new repos start in LastGit
                        while existing venue choices remain unchanged until
                        explicitly migrated
routines/<name>.md      one parameterized scheduled-agent template per routine
routines/README.md      how routines + skills compose; how to register them
templates/routine-fleet/
                        portable Brain record templates for project routine
                        config, probe registries, and shared SOPs
```

## How an AI agent uses this

The intended loop, end to end:

1. **File work as cards** (`kanban` skill). A card body is the spec: a `Repo:` /
   `Base:` header plus GOAL / STEPS / VERIFY / DONE WHEN. Cards live on your
   LastDB node.
2. **Drive one card to merged** (`kanban-agent` skill, WORK mode). The agent
   claims the card, works in an isolated git worktree, opens a PR, and then
   *drives that PR to MERGED* — re-arming auto-merge, updating a behind branch,
   rebasing conflicts — before moving the card to `done`, or leaving it in
   `todo`/`doing` with a clear `BLOCKED:` marker when the END STATE requires an
   async post-merge check. A card is only `done` when its code is actually in
   the repo and the outcome is proven.
3. **Wait on PRs without false failures** (`wait-merge` skill). Interprets PR
   state rather than trusting a watcher's exit code, so transient CI/queue churn
   doesn't look like a failure.
4. **Reconcile the board** (`kanban-agent` skill, RECONCILE mode). A scheduled
   sweep moves merged-but-unadvanced cards to `done` and nudges stuck PRs —
   leaving un-started cards alone.
5. **Validate post-merge outcomes** (`kanban-agent` skill, VALIDATE mode). A
   scheduled pass runs one dev-only post-merge END STATE check, then moves the
   card to `done` on pass or leaves it visibly blocked with `PROOF:` plus a fix
   card/blocker on fail.
6. **Close out** (`close-out` skill). After any substantive change: PR from a
   worktree, drive to merged, checkpoint the *why* to the brain (`brain`), and
   file any follow-up as a card (`kanban`).

The two halves are deliberate: **the brain records why; the board records
what's in flight.** Keep decisions in `brain` and active work in `kanban`, and
the agent always has both context and a worklist.

Steps 1–6 describe what an agent does *when invoked*. To make the loop
**self-driving** — so cards get filed, promoted, picked up, and reconciled
without a human kicking it each time — register the **routines** as scheduled
agents: generators (`self-improvement-loop`, `papercut-reconciler`) file work,
`north-star-driver`, `milestone-driver`, and `groom-board` promote it, separate
`kanban-pickup` workers claim and ship one WORK card each, `pipeline-health`
and board-reconcile (`kanban-watch` plus closeout/reaper) reconcile the
stragglers, `kanban-validate`
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
the **kanban-setup** skill and the `kanban` / `brain` repos.

## Configuring the node URL

Every skill talks to a LastDB node over HTTP. The node URL is **configurable** —
`kanban init` defaults to a node running locally on your machine, and you
override it with `--node-url` (and `--schema-service-url` for a different schema
service). Point the skills at whichever node hosts your board and brain.

## License

MIT — see [LICENSE](LICENSE).

See also [docs/lastdb-no-product-scan.md](docs/lastdb-no-product-scan.md).
