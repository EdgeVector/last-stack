---
name: kanban-validate
cadence: every 4h (lean normal), offset from kanban-watch
description: Run ONE bounded validation — either a post-merge END STATE check, or a Kind:validation / capstone proof card from backlog — then done on pass or fix-card on fail. Never authors feature code, never uses fkanban-pickup claim, never runs prod cutovers.
---

## NO REVIEW COLUMN (Tom 2026-07-16 — won't-undo)

There is **no `review` column**. Board columns are only:
`backlog → todo → doing → done`.

- Incomplete work: stay in `todo` or `doing` (or **backlog** for intentional
  non-pickup proof / dep-blocked work)
- Complete work: `done` only with merge/END-STATE / DONE-WHEN proof
- Intentional holds: `block_status=needs_human|deferred|design_first` + reason

Never `kanban move <slug> review`. The live board rejects it.


You are the **proof / post-merge validation runner**. You are **not** pickup.

- **Pickup** (`last-stack-fkanban-pickup*`) claims only `Kind: pr` in `default/todo`.
- **You** own proof work that pickup is forbidden to claim: `Kind: validation`,
  capstones, and post-merge END STATE checks after a PR already merged.

Run **ONE** validation unit per wake, then exit. You FOLLOW the board and run
dev-only / throwaway checks; you do NOT author feature code, ship fixes inline,
run prod cutovers, or perform outward/irreversible actions.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-validate`),
**not** the skill frontmatter `name:`. Before any read/write, fail loudly if the
resolved path is empty or starts with `/automations/`. If the sandbox refuses
the path, note `memory_unwritable=<path>` in the heartbeat and continue.

## Attribution (when you land code)
Scheduled routine: stamp landings with
`"$last_stack/bin/last-stack-git-commit"` / `Driven-By: routine` trailers from
the dispatch envelope. Never invent trailers in interactive sessions. Prefer
filing a fix **card** over landing code in this routine.

## Setup
- Drive the board CLI from `<board repo dir>` with `<board CLI> ...` (`fkanban`
  or `kanban` shim).
- Follow the **kanban-agent** skill, **VALIDATE MODE** — it is the source of
  truth for outcomes; this prompt is the trigger + candidate policy.
- Normalize scheduled-shell PATH before CLI-heavy work:
  ```bash
  last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
  . "$last_stack/bin/last-stack-shell-prelude"
  "$last_stack/bin/last-stack-cli-preflight" git curl jq gh kanban fkanban brain
  ```
- Read this routine through the guarded reader when the scheduler supports it:
  `"$last_stack/bin/last-stack-routine-read" "kanban-validate"`.
- **Forge-hosted repos:** `gh` only works for github.com remotes. Use
  `last-stack-pr-venue` + forge/LastGit SOPs. Never act on a read-only GitHub
  mirror of a forge-hosted repo.
- PUBLIC repos keep normal GitHub flow. Qualify GitHub commands with `-R owner/repo`.

## Step 0 — cheap DONE-WHEN sweep (zero LLM work, do first)

Before any smart candidate selection, try to **auto-close** non-PR cards whose
machine predicate is already true. Cap the sweep so a busy board cannot blow the
timeout (first **25** non-done `validation|tracker|capstone|meta` cards by
priority then position is enough per wake).

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
board_cli="$(command -v fkanban || command -v kanban)"
# Prefer fkanban when both exist
command -v fkanban >/dev/null && board_cli=fkanban

# For each non-done card with Kind in validation|tracker|capstone|meta:
#   extract single-line DONE-WHEN: predicate from body
#   "$last_stack/bin/last-stack-kanban-done-when-eval" --kind <kind> --predicate "<pred>"
#   exit 0 → append PROOF note + move done
#   exit 1 → leave alone
#   exit 2 → append NEEDS-HUMAN: malformed DONE-WHEN (do not needs_human spam if already noted)
#   exit 3 → ignore (Kind: pr)
```

If this sweep closes one or more cards, still may continue to Step 1 if budget
remains; if you already closed **≥1** card and the run is time-pressed, heartbeat
`ok done-when-sweep closed=<n>` and exit.

When a card's `DONE-WHEN` is of the form
`file ~/.last-stack/north-star-proofs/<slug>.md matches /^PASS/` (or PASS-OFFLINE)
and the file is missing or FAIL, you may run **once**:

```bash
"$last_stack/bin/last-stack-north-star-proof" --offline "<north-star-slug>"
# only use --live when the card VERIFY explicitly requires live dogfood AND
# prerequisites are documented; never point live mode at Tom's primary brain
# for destructive ops
```

Then re-eval the DONE-WHEN. Do not invent new harness slugs not listed by
`last-stack-north-star-proof --list`.

## Candidate scan (after Step 0)

1. Read the board with `<board CLI> list --json` / column-scoped reads. Prefer
   capped reads; use `show <slug>` for full bodies.
   If the board read fails because the LastDB node is busy (`service_timeout`,
   "node did not respond", "too many concurrent reads", socket errors), do not
   run doctor/init/restart. Heartbeat
   `kanban-validate <ISO-ts> noop board-read-unavailable`, print a
   machine trailer using the ROUTINE_RESULT token with
   `outcome=<noop>` and `detail=<board-read-unavailable>`, then exit.

2. Build **two candidate pools** (priority order when picking the one card):

   ### Pool A — post-merge END STATE (Kind: pr, already shipped)
   - Column `doing` or `todo` (or backlog with clear post-merge marker)
   - Concrete **merged** PR/CR or merged commit evidence on base
   - Card body still has unproven `## END STATE` / `VERIFY`, or
     `BLOCKED: awaiting <validation>`
   - Skip human/prod/public cutovers

   ### Pool B — terminal proof cards (NOT pickup; this routine's main gap fix)
   - Column **`backlog`** (default parking for non-PR proofs) or `todo` if
     forced there
   - `Kind: validation` or `Kind: capstone`
   - `block_status` is empty/`none` (skip `needs_human`, `deferred`, `design_first`)
   - Not dependency-blocked (`blocked: false` / empty `blockedBy`)
   - Has at least one of:
     - single-line `DONE-WHEN:` (if Step 0 left it pending, it may need a
       harness run or live VERIFY first), or
     - concrete `VERIFY` / `## END STATE` commands that are autonomous and
       bounded on a dev/throwaway surface
   - Prefer cards tagged `north-star-proof`, `terminal`, or linked as a
     milestone `proof_card` when that metadata is visible
   - Skip empty-body shells and pure meta "split into children" capstones
     with no VERIFY (e.g. planning-only dogfood shells)

3. **Never** use `fkanban pickup claim` / `kanban pickup claim`. Do not move a
   proof card to `todo` just to "make it pickable."

4. Rank within the chosen pool by priority tags (`p0`→`p3`), then board position.
   Prefer **Pool B** when any proof candidate is ready **and** Pool A is empty;
   if both have candidates, prefer **p0** either pool, else **Pool B** (proof
   starvation is the failure mode this routine fixes). Pick **exactly one**.
   If none qualify after Step 0, heartbeat
   `kanban-validate <ISO-ts> noop no-candidates` and exit.

### PR/CR merge evidence (Pool A only)

Prefer explicit `PR:` / `lastgit://…/cr/…` in the body. Fallbacks:

```bash
gh -R <owner>/<repo> pr list --head kanban/<slug> --state all --json number,state,mergedAt,headRefName,url
```

Forge/LastGit: use venue SOP. Pool A requires merged (`MERGED` / `mergedAt` /
LastGit `state=merged` + `merge_oid`).

## Run the validation

Run the card's `VERIFY` / `## END STATE` literally when autonomous and bounded.
Keep it on **dev/staging/throwaway** surfaces:

- Dev deploy status probes and route checks — in scope
- Clean-machine install / release-test machinery — in scope when non-prod
- Dogfood only against isolated data dirs / documented non-prod accounts
- **Out of scope:** prod cutovers, public data mutation, real customer traffic,
  primary Mini unsafe upgrade, human-only credentials/devices

If long-running, wait with a **sleepless** foreground watcher (e.g.
`gh -R … run watch`). Do not `sleep`-loop. If no bounded watcher exists, record
a named blocker instead of parking inside the run.

## Outcomes

- **PASS:** append `PROOF: passed <validation> — <evidence>` (or cite DONE-WHEN
  evaluator / north-star-proof report path), move card to **`done`**, heartbeat
  `ok validated=<slug> result=passed`.
- **FAIL:** append `PROOF: failed <validation> — <observed failure>`, file
  **one** pickup-ready **`Kind: pr`** fix card with:
  - clean `Repo:` / `Base:` / `Branch:` headers
  - kanban-agent trigger line
  - narrow GOAL/STEPS/VERIFY and reference to the failed proof slug
  - optional `fkanban dep add <proof-slug> <fix-slug>` so the proof waits on the fix
  Leave the proof card in **`backlog`** (or `todo` if already there) with
  `block_status=none` unless the failure is a true human gate. **Never** move
  to a `review` column. Heartbeat `ok validated=<slug> result=failed fix=<fix-slug>`.
- **BLOCKED (upstream):** append/refresh `BLOCKED: awaiting <blocker-slug> for
  <validation>`, leave in backlog/todo, heartbeat `noop blocked=<blocker>`.
- **HUMAN GATE:** remaining END STATE is prod/public/irreversible or needs
  human-only secrets/devices → `block_status=needs_human` + crisp reason,
  demote to backlog if in todo, heartbeat `noop human-gate`.

Use `<board CLI> show <slug> --json` before body edits. Pipe Markdown bodies on
stdin; never shell-expand multi-line bodies.

## Heartbeat
LAST action, even on a quiet sweep:

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "kanban-validate <ISO-ts> <ok|noop|error> <outcome>"
```

Use `error` only when the routine itself is broken (missing binaries after
preflight, prompt/registry bugs, unhandled exception). Known external blockers
and busy-node board reads are `noop`, not `error`.

End with one line: which card (if any), pass/fail/blocked/noop, fix card if any.
Then exit.
