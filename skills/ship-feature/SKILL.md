---
name: ship-feature
description: |
  Take a feature the user wants to "make sure works" and drive it to done
  autonomously: scope how much work it is, design it, surface ALL open
  questions at once with ELI5 explanations + recommendations, get one plan
  approval, then hand the outcome to the North Star → milestone → Kanban routine
  pipeline and drive it unattended until the feature is validated by ACTUALLY
  RUNNING THE APP, not just passing tests.
  Batch every decision up front, then work until proof or a genuinely new blocker.
  Use this when the user says "make sure this feature works", "ship this
  feature", "/ship-feature ...", "drive this to done", "I want X to work and
  I don't want to babysit it", "automate building and validating a feature",
  or otherwise asks for an end-to-end build-and-prove-it workflow they can
  walk away from. Prefer this over ad-hoc coding whenever the request implies
  unattended, looped, end-to-end delivery with a validation gate.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Skill
  - Agent
  - AskUserQuestion
  - ScheduleWakeup
  - TaskCreate
  - TaskUpdate
  - TaskList
---

# /ship-feature — scope → design → ask once → North Star → drive → prove

The user hands you a feature and wants confidence it **works**. They do **not**
want to sit and monitor. Your job is to compress every human decision into one
batch up front, get a single plan approval, then go fully autonomous on **one
hierarchy only**:

```
Brain North Star (Mode: ship + Terminal verification)
  → Milestone (via north-star-driver)
    → Kind:pr cards + proof card (via milestone-driver)
      → pickup merge → product proof (feature-prove / you)
```

**Do not create `feature-owner` cards** (retired 2026-07-22). Canonical SOP:
brain `sop-feature-ship-loop` / `preference-feature-ship-loop`.

Treat "it works" as a claim you must *demonstrate*, not assume. Tests passing is
necessary but not sufficient — the stop condition is the app running the feature
(the North Star terminal proof).

## The contract with the user (their stated preferences — honor them)

1. **All open questions surfaced at once**, up front, each with an ELI5
   explanation, a recommendation, and the recommended option first.
2. **One plan approval**, then **fully autonomous** to completion.
3. **Quiet until done or blocked** — only interrupt them when finished, stuck,
   or you hit a *new* decision you genuinely could not have asked up front.
4. **Validation = the app actually runs the feature.** Not "tests green," not
   "PR merged." Those are intermediate events, not the finish line.

If you ever feel tempted to ask a question mid-loop, first ask yourself: *could
I have anticipated this during scoping?* If yes, you broke contract #1 — make a
reasonable call using the decision principles below and keep going. Only surface
mid-loop for things that were genuinely unknowable up front (e.g. a design
choice that only appears once a dependency's real behavior is observed).

---

## Phase 0 — Intake & baseline

The feature description is in the invocation (`/ship-feature <description>`). If
it's missing or one word, ask for a one-paragraph description of what "working"
looks like — that's the only thing you cannot proceed without.

**Before scoping, check whether it already works.** The user said "make sure it
works" — maybe it already does. Establish a baseline:

- Identify the repo/crate involved (default cwd; the user works under
  `~/code/edgevector/` — see that workspace's CLAUDE.md for which dir is real
  vs. an archived snapshot).
- `git fetch` and read `origin/<base>` state, not just local — local checkouts
  here lag origin/main routinely.
- Try to exercise the feature as it stands (see Phase 6 validation method). If
  it already works, say so, show the proof, and stop. Don't manufacture work.

If it partially works, note exactly what's missing — that *is* your scope.

## Phase 1 — Scope (how much work?)

Delegate the investigation; don't read the whole tree yourself. Spawn an
`Explore` agent (or `Plan` agent for design-heavy features) to answer:

- What exists today vs. what the feature needs.
- The concrete change surface: files, modules, schemas, lambdas, configs.
- Dependencies and ordering — what must land before what.
- How the feature is *exercised* (entry point, command, endpoint, UI path) —
  you need this for validation, so capture it now.
- Rough size: is this one PR or several? Sequential or parallelizable?

Land on an honest size estimate: number of tasks, rough dependency graph, and
whether tasks can run in parallel (mind the workspace's resource limits; fold no
longer has a fixed two-agent build/test cap, but high-concurrency Rust builds
still need disk/load awareness; see references).

## Phase 2 — Design

Produce a tight implementation design:

- Decompose into **Kanban-task-sized units** — each independently landable as
  one PR, each with a clear acceptance check.
- Define the **F-Kanban milestone graph**. Create one milestone per independently
  provable product outcome; default to one milestone for one approved feature.
  Use milestone dependencies only when the approved plan contains multiple
  outcomes that must land in sequence.
- Define the **acceptance criteria** centered on running the app: "when X is
  done, running `<command/endpoint/path>` produces `<observable result>`."
- Note risks and the validation plan (how you'll prove the whole thing at the
  end).

Keep the design in memory / a scratch doc; you'll present its essence at the
approval gate. For EdgeVector, design docs belong in
`exemem-workspace/docs/<subdir>/` if the user wants a durable copy.

## Phase 3 — Surface ALL open questions, at once, ELI5

This is the heart of the contract. Collect **every** decision, ambiguity, and
fork from Phases 0–2 into a single batch and present them with `AskUserQuestion`.

Rules for the batch:

- **Consolidate ruthlessly.** `AskUserQuestion` shows up to 4 questions per
  call. Pick the 4 highest-leverage decisions — the ones that actually change
  what you build. Roll trivia into your own defaults. If more than 4 are truly
  load-bearing, make consecutive `AskUserQuestion` calls with **no work in
  between** so it reads as one sitting — never drip questions across the loop.
- **Every option gets an ELI5.** Write the `description` as if explaining to a
  smart person outside the codebase: what this choice means and the tradeoff,
  in plain words, no jargon. Avoid acronyms unless you expand them.
- **Recommend.** Put your recommended option **first** and append
  `(Recommended)` to its label. The user picked all-recommended-defaults before;
  make the safe path the obvious one.
- **Only real decisions.** If you can answer it yourself from the code or a
  sensible default, do — don't pad the batch with questions you could resolve.

If there are genuinely zero open questions, skip straight to Phase 4 and say so.

## Phase 4 — One plan approval gate

Present a concise plan the user can approve in one read:

- One-line restatement of the feature and what "done" will look like.
- The task list (titles + one-line each) with the dependency order.
- The milestone outcome(s), owning North Star when one already exists, and the
  terminal proof card for each milestone.
- How long-ish / how many agents, and the validation you'll run at the end.
- The answers from Phase 3 folded in.

Then get a single yes/no. After approval, **do not ask again** unless contract
#3's "genuinely new blocker" clause fires. Make this the last routine touchpoint.

## Phase 5 — Materialize North Star + drive via hierarchy

Hand the approved plan into the hierarchical routine pipeline. Ship It is the
intake/orchestration layer; it must not directly create milestones or Kanban
cards. (Brain North Star create/reuse is allowed; board graph creation is not.)

**Do not create `feature-owner` cards** — retired 2026-07-22. One hierarchy only:
North Star → milestone → Kind:pr + proof.

### HARD RULE — no bulk board scaffolding (won't-undo)

After creating or selecting a North Star, **never** bulk-write milestones and
empty `Kind: pr` shells with `fkanban add` / `fkanban milestone add` in the same
session. That is what produces hollow cards, false `needs_human` holds, and
wrong `driver: program-driver` milestones.

**Allowed:**
- Brain NS create/update + `brain append` of `MILESTONE_REQUEST …`
- Targeted `routines run last-stack-north-star-driver` / `last-stack-milestone-driver`
- Observing with `fkanban milestone detail` / `pickup explain`

**Forbidden:**
- Creating more than zero implementation cards yourself for a new NS outcome
- Filing header-only PR bodies (`Repo`/`Base` only) into `todo`
- Setting milestone `--driver program-driver` (superseded; default is
  `last-stack-milestone-driver`)
- Filing board `feature-owner` validation cards

If the user says "make this a North Star" or "start driving this," do **intent
only** (NS + `MILESTONE_REQUEST` + targeted driver dispatches), not a full fake
DAG.

**Required materialization (after plan yes):**

1. **Create or reuse one Brain North Star** (`type: project`, slug
   `north-star-<kebab>` when new). Reuse a clearly matching active North Star
   rather than minting a twin for a tiny delta. Body **must** include:

   - `**Mode:** ship`
   - `## End state` (Tom-visible product outcome — same words as intake)
   - `## Terminal verification` with **Card:** `<proof-slug>`, shape, Done means,
     deploy surface if any

   Do not invent or broaden strategic intent after approval.

2. Append an idempotent request to that North Star using `brain append`:
   `MILESTONE_REQUEST slug=<milestone-slug> status=pending`, followed by the
   approved Outcome and Acceptance text. Never rewrite a large North Star to add
   the request. Default **one milestone** per feature unless the approved plan
   has multiple independently provable outcomes.

3. Trigger the North Star routine for the exact request:
   `NORTH_STAR_DRIVER_TARGET=<north-star-slug>` and
   `NORTH_STAR_DRIVER_REQUEST=<milestone-slug>` with
   `routines run last-stack-north-star-driver`. The routine—not Ship It—creates
   the milestone scaffold. If manual dispatch is unavailable, leave the durable
   pending request for its scheduled pass.

4. Confirm the milestone exists and matches the approved North Star/outcome via
   `fkanban milestone detail <milestone-slug> --json`. Expect
   `driver=last-stack-milestone-driver`.

5. Trigger targeted bounded passes with
   `MILESTONE_DRIVER_TARGET=<milestone-slug> routines run last-stack-milestone-driver`
   until the milestone has a linked terminal proof and at least one concrete
   `Kind: pr` frontier, or reports a real blocker. The milestone routine—not
   Ship It—creates and links those cards. Never bypass the routine by writing
   the graph directly.

6. **Acceptance before walk-away:** for each claimed "runnable" PR slug run
   `fkanban pickup explain <slug> --json` and require `ready: true`. Reject
   header-only bodies and `driver: program-driver` milestones.

Materialization is invalid until `fkanban milestone detail` and
`fkanban milestone groom --json` confirm the two routine ownership boundaries,
driver, proof link, child links, North Star agreement, and executable frontier.
It is also **invalid** if only a tracker or legacy feature-owner exists, or if
the North Star lacks Terminal verification.

Use the **`kanban` skill** to observe and manage cards after the milestone driver
has generated them—it already knows this workspace's board, merge, and
babysitting mechanics. For each slice:

- **Every task prompt MUST start with a header telling the agent to follow the
  `kanban-agent` skill and see it through to a merged PR** — without it the
  agent finishes locally and never opens a PR. Example header:
  > Follow the kanban-agent skill — see this through to a merged PR.
- Write self-contained prompts: paths, the acceptance check, the base branch.
  Verify `origin/<base>` before referencing "current state."
- Respect dependency order — don't create a task whose prerequisite hasn't
  merged unless they're genuinely independent.
- Respect resource limits (fold: no fixed <=2 build/test cap; use the repo's
  worktree-concurrency proof when changing the test harness, and watch disk/load
  before launching many Rust builds).

Then enter the loop. See `references/loop-playbook.md` for the full driving and
recovery playbook — read it before/while you start the loop.

## Phase 6 — Loop until validated (unattended)

You are now heads-down. Drive with a **ScheduleWakeup heartbeat** — do **not**
use the Monitor tool (its notifications don't reach this user). Kanban agents run
as separate sessions, so you must poll: schedule a wakeup (default ~1200s — long
enough to make progress, the user can always interrupt), and on each wake:

1. **Read board + PR state** (via the kanban skill). Which tasks merged? Which
   are in progress, stuck, or wedged?
2. **Recover wedges** (see references — there's a whole taxonomy: API-400
   thinking wedge, 529 wedge, bg-notification wedge, killed-task wedge, etc.).
   Recovery is usually trash + recreate the task, never a server restart.
3. **Unblock the next tier** — when a prerequisite merges, create the dependent
   task or let `last-stack-milestone-driver` promote the existing linked
   frontier. Do not create a second milestone for the same approved outcome.
4. **When all milestone slices are merged → VALIDATE** (Phase 7). This is the
   real gate. A milestone completes only after its linked terminal proof passes
   and `fkanban milestone state <slug> complete --proof-status passing` is
   accepted. Then mark the ship-mode North Star done if this was its terminal.
5. **Re-schedule** the next wakeup unless fully done. **Stop scheduling** once
   validated — that ends the loop cleanly.

Keep silent across heartbeats (contract #3) unless something needs the user.

## Phase 7 — Validation: run the real app

This is the stop condition. **Pull the merged code and actually run it.**

- Prefer the **`verify`** skill (purpose-built: run the app, observe behavior,
  confirm the change does what it should) or the **`run`** skill (launch/drive
  the project's app). Use the entry point you captured in Phase 1.
- Observe the feature producing its expected, observable result — the
  acceptance criteria from Phase 2.
- For services/endpoints: hit the real endpoint and check the response. For
  CLIs: run the command and check output. For LastDB-node work: exercise via
  the running node — **never against Tom's primary LastDB brain** unless explicitly
  told; spin an ephemeral node (the app-identity-dogfood skill shows the
  pattern).

**If validation passes:** stop the loop, write the final report (Phase 8).

**If validation fails:** this is expected sometimes. Diagnose, file a
fix-forward Kanban task (with the trigger header), and **keep looping**. A
failed validation is not a question for the user — it's just more work. Only
surface to the user if you're truly stuck (same task fails validation ~3 times
with no path forward, or a decision appears that you couldn't have foreseen).

## Phase 8 — Report (the one proactive ping)

When validated, send one clear summary:

- ✅ The feature, and the **proof it works** (the command/endpoint you ran and
  the observable result — paste it).
- The PRs that landed (links).
- Anything you decided autonomously that's worth knowing.
- Any follow-ups you flagged but didn't do.

If you had to give up, report instead: how far you got, exactly what's blocking,
and the smallest decision you need from the user to continue.

---

## Decision principles (for autonomous calls during the loop)

When you must decide without the user (contract #1 said ask up front; the loop
is heads-down), default toward:

1. **Reversible over irreversible** — prefer choices easy to undo.
2. **Smallest change that satisfies the acceptance check** — don't gold-plate.
3. **Match the surrounding code** — its conventions over your preferences.
4. **Dev/ephemeral over prod** — never touch prod when a plan is in flight; do a
   clean cutover only when the model is final (the user is firm on this).
5. **Proper fix over quick patch** — durable (CDK+redeploy, PR, source change)
   over band-aids (env overrides, monkey-patches).
6. **When genuinely blocked on the user's call** — that's the only time you
   break silence mid-loop.

## Hard guardrails (this workspace)

- **Never kill the primary LastDB brain** — that's Tom's brain. Identify
  it by its socket (`lsof /Users/tomtang/.lastdb/data/folddb.sock`) or process
  (`pgrep -fl 'lastdbd|folddb_server'`) before killing any LastDB-like process — the TCP port is
  gone, so a port probe no longer finds it.
- **Never stash/reset/restore** in a shared repo — other agents share the
  worktree. Use `git worktree add` instead.
- **Don't touch archived predecessor repos** (`fold_db/`, `schema_service/`,
  `fold_db_node/` as standalone dirs) — use the `fold/` monorepo.
- **Don't restart the kanban server unattended** — it kills every live agent
  across all workspaces. Trash-and-recreate clears a wedge without a restart.
- **A non-zero-exit Bash call cancels queued tool calls** in scheduled/headless
  runs — append `|| true`, one logical step per call.

See `references/loop-playbook.md` for the detailed driving + wedge-recovery
procedures and the relevant memory pointers.
