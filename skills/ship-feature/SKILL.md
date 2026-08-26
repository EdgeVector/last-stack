---
name: ship-feature
description: |
  Take a feature the user wants to "make sure works" and drive it to done
  through the loom software factory: kick off the ship-feature v4 graph, which
  designs the feature (design artifact + ideal state + decisions), hard-parks
  at a human approval gate, then ships automatically — parallel slices, live
  proof on the real surface, and a review that deep-dives on drift and loops a
  gap-addressing plan back through design and re-approval. The skill is the
  human-side driver: compose the input, relay the gate, signal the user's
  answer, babysit to DONE, and independently verify the proof.
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

# /ship-feature — the loom factory drives it: design → gate → ship → review

The user hands you a feature and wants confidence it **works**. They do **not**
want to sit and monitor. Since 2026-08-26 the engine for this is **loom's
`ship-feature` v4 graph** (brain: `north-star-factory-on-loom`,
`design-loom-agent-orchestrator` § "Factory on loom"):

```
DESIGN → APPROVE (human gate, hard park)
  → DECOMPOSE → map(ship-slice: PR → CI → merge) → join
    → PROVE_LIVE (real surface) → REVIEW
      → pass → CLOSE_OUT (brain record) → DONE
      → drift/blocker → DEEP DIVE → new plan → DESIGN delta → re-approve → ship again
```

Your job is the human side of that machine: compose a correct kickoff, relay
the gate to the user, execute THEIR answer as a `loom signal`, babysit to
`DONE`, and verify the proof yourself. The graph does the designing, the
shipping, the reviewing, and writes its own closeout.

Treat "it works" as a claim you must *demonstrate*, not assume. The stop
condition is the graph's `PROVE_LIVE` passing on the real surface — and you
re-running that proof independently.

## The contract with the user (honor it)

1. **One gate, up front.** The graph's DESIGN node batches the decisions into
   the design artifact; the user approves once per revision. Do not drip
   questions around the gate.
2. **After the yes, fully autonomous.** No node asks the user anything until
   the walk finishes or a drift loop parks a new revision.
3. **Quiet until done, blocked, or re-parked.** A drift re-park is a
   legitimate interruption — it is a new revision that needs a new approval.
4. **Validation = the live surface.** `proof_command` green, verified by you
   as well as by the graph. Tests and merges are intermediate events.

## Venue check (do this FIRST)

The ship-slice scripts ship through `gh`. Today the factory handles repos
whose PR venue is **github** only:

```bash
last-stack-pr-venue <owner/repo> <repo-root>   # github | forgejo | lastgit
```

- `github` → factory path (this skill, below).
- `forgejo` / `lastgit` → **fallback**: the legacy North Star → milestone →
  cards pipeline (see "Legacy fallback" at the end). Do not force the factory
  onto a venue its scripts cannot ship to.

## Phase 0 — Intake & baseline

The feature description is in the invocation. If it is missing or one word,
ask for a one-paragraph description of what "working" looks like.

**Check whether it already works.** Identify the repo, `git fetch`, read
`origin/<base>`, and try the feature's entry point. If it already works, show
the proof and stop — do not manufacture work. If it partially works, the gap
is your brief.

Preflight the factory:

```bash
loom ping                        # node reachable
```

If `loom` is missing or the node is down, do not improvise — check
`~/.local/bin/loom` (host-track artifact) and the node per the workspace
CLAUDE.md, or use the legacy fallback and say so.

## Phase 1 — Compose the kickoff input

For a LastDB-shaped feature, pull the design corpus BEFORE writing the brief,
so the brief cannot contradict settled designs:

```bash
last-stack-design-pack --topic "<feature paragraph>" --out /tmp/design-pack.md
```

Three fields carry the whole feature. Get them right; the graph does the rest.

- **brief** — one done-looking paragraph: the outcome, not the steps.
- **proof_command** — a shell command that checks the LIVE surface and exits 0
  only when the feature works. Prefer one greppable token. This is the
  feature's definition of done; a weak proof is a false completion waiting to
  happen.
- **repo / base** — `owner/name` with a local checkout; base defaults `main`.

**Input rules (the node scripts extract fields with sed):**

- No double quotes inside `brief` or `proof_command`. Single quotes are fine.
- `force_drift_until_rev` is a loop-exercise flag for tests. Never set it for
  a real feature.

Pick a deterministic key: `ship-<feature-kebab>-<yyyymmdd>`. The same key
always resumes the same execution — never mint a second key for a retry.

## Phase 2 — Kick off, park at the gate

```bash
LOOM_LIVE=1 loom run ship-feature --key <key> --input '{"repo":"<owner/name>","base":"<base>","brief":"<paragraph>","proof_command":"<check>"}'
```

Expect `status: parked`, `state: AWAIT_APPROVAL`, `design_rev: 1`. The DESIGN
node has written the design artifact (path in `context.artifact_url`, under
`~/.loom/designs/`) and GATE_OPEN has put the gate line on the brain
`open-decisions` ledger with the exact resume command.

Anything else is a defect: diagnose with `loom show <execution-id>`, fix or
file, do not push past it.

## Phase 3 — The gate (the user decides; you are their hands)

**Interactive session (the normal case):** present the design to the user —
the artifact, the ideal state, the decisions with recommendations — and get
one answer with `AskUserQuestion` (approve / revise). Then execute it:

```bash
loom signal <execution-id> design-approval --payload '{"approval":"approve"}'
# or:
loom signal <execution-id> design-approval --payload '{"approval":"revise","plan":"<their notes>"}'
```

A revise re-runs DESIGN with the notes and parks a new revision — relay it and
ask again.

**User not present / headless invocation:** STOP at the park. The gate line on
`open-decisions` is the surface; morning-sync will bring it to the user. Never
signal an approval the user did not give. There is no autonomous path through
this gate — that is the design, not a limitation.

## Phase 4 — Babysit to DONE

The approval signal itself drives the automatic pass in-process — run it with
a long timeout in the background. Then watch:

```bash
loom show <execution-id>
```

- **`status: parked` again** → a drift loop fired. `context.plan` holds the
  deep dive's gap-addressing plan and `context.artifact_url` the revision
  delta. Relay to the user, get the next answer, signal again (Phase 3).
- **`status: failed`** → read the failing node and `last_error`. A replayable
  node (`effects: none`/`idempotent`) retries by re-running the SAME
  `loom run … --key <key>` command. A parked `checked` node has its evidence
  attached — resolve it honestly, never by forcing state.
- **Interrupted / node restarted** (safe-upgrade cutovers happen) → the replay
  contract holds: re-run the same `loom run … --key <key>`. Completed nodes
  are cached; only the in-flight frontier re-runs.
- **Poll cadence:** ScheduleWakeup ~1200s while a pass runs unattended. Do not
  use the Monitor tool.

## Phase 5 — Verify and report

`status: succeeded` is the graph's claim; verify it yourself before repeating
it:

1. Run `proof_command` yourself against the live surface — paste the result.
2. Confirm the merged PR(s) exist (`context.slice_results`, `gh pr list`).
3. Confirm the graph's own closeout record exists:
   `brain get closeout-loom-<execution-id-lowercased>`.

Then send the one proactive report: the feature, the pasted proof, the PRs,
the execution id, anything decided autonomously, and follow-ups flagged. If
you gave up instead: how far, what blocks, and the smallest decision needed.

## Decision principles (autonomous calls between gates)

1. Reversible over irreversible.
2. Smallest change that satisfies the proof.
3. Match the surrounding code.
4. Dev/ephemeral over prod — never touch prod while a plan is in flight.
5. Proper fix over quick patch. A defect the walk exposes in the factory
   itself gets fixed and merged (loom repo, venue lastgit), papercut filed —
   the factory debugging itself is normal operation.
6. Only the gate breaks silence.

## Hard guardrails (this workspace)

- **Never kill the primary LastDB brain** (`lastdbd` on
  `~/.lastdb/data/folddb.sock`). A refused socket during a walk is usually a
  safe-upgrade cutover — wait, then resume with the same key.
- **Never signal an approval the user did not give.** The gate is the product.
- **Never stash/reset in a shared checkout**; worktrees only.
- Input fields must not contain double quotes (sed extraction in node
  scripts).
- Push to `lastdb:///` remotes with `--no-thin` and clone-verify before
  opening a CR (poisoned thin-pack papercut).

## Legacy fallback — North Star → milestone → cards

Use ONLY when the venue check says `forgejo`/`lastgit`, or loom is genuinely
unavailable. The flow is the pre-factory pipeline; its SOP of record is brain
`sop-feature-ship-loop`:

- One hierarchy: Brain North Star (`Mode: ship`, `## Terminal verification`)
  → milestone → Kind:pr + proof cards → pickup → product proof.
- Materialize with `last-stack-ship-handoff` (heading-form
  `## MILESTONE_REQUEST` only). **No bulk board scaffolding, no
  feature-owner cards, no cards created by this skill** — the milestone
  driver creates them.
- Walk-away gate: `kanban pickup explain <slug> --json` reports
  `eligible_for_claim: true`.
- Drive and recover with `references/loop-playbook.md`.

Follow-up on record: teaching the ship-slice scripts the forgejo and lastgit
venues retires this fallback (see the factory North Star).
