---
name: morning-sync
cadence: daily
description: Deliver a daily briefing — progress being driven (§🚀) + genuinely-human decisions (§⚠️) + whether last night's new releases actually work on this machine (§🔬) + scoping/health/overnight. Read-only; autonomy-first framing.
---

Produce and DELIVER the daily briefing. This is READ-ONLY — do not move cards,
edit gate cards, or run `kanban-agent`. The only writes are (a) upserting the
brief to a `morning-sync-brief-latest` note in your brain and (b) one heartbeat
line. You start cold with no memory of prior runs.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-pickup`),
**not** the skill frontmatter `name:` (e.g. not bare `kanban-pickup`). Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly. If the
sandbox refuses the path, note `memory_unwritable=<path>` in the heartbeat and
continue — do not fail the whole run.

> **CRITICAL framing:** the fleet DRIVES autonomously toward the goal; it does NOT
> gate on caution. So this brief is NOT a decision-fatigue queue. Most "gates" are
> autonomous (driven by `program-driver`/`kanban-agent`) and must NOT be surfaced
> as decisions. The job is to show progress and surface ONLY what genuinely needs
> a human.

## The brief skeleton
Lead with a one-line restatement of the goal / top objective, then:

- **§🚀 "What I'm driving"** — a short list of the dev/security/design work being
  promoted/generated toward the goal, so the human sees progress and can redirect.
  NOT approval requests.
- **§⚠️ "Genuinely needs you"** — ONLY the human set: prod cutovers / public
  launches (irreversible, outward), shipping NEW capability to END USERS,
  brand/naming/tagline, business/legal, a genuinely-novel architecture fork. Plus
  `open-decisions` escalations + the driving index's `needs-human` /
  `blocked-needs-human` lines. Prefer brain **`human-gate-audit-latest`**
  (written by routine `human-gate-audit`) as the pre-classified source:
  use its **REAL_HUMAN** and **Waiting on recommendation** sections; ignore
  holds already marked NOT_A_BLOCKER / cleared. Dedup by slug. Do NOT list
  dev-enable / security-review / design-first cards here — those are being
  driven. **If §⚠️ is empty, say so — that's the goal.**
- **§🧩 Needs scoping** — active programs with no card whose next move is concrete
  but un-carded.
- **§🩺 Routine health** — from your scheduler's last-run timestamps + the
  `routine-heartbeats` note; flag any routine stale-vs-cadence or errored.
  If `brain get routine-reds-recheck-latest --type reference` exists and is
  newer than 36h, paste its table here (fleet reds Tom asked to recheck —
  working / pending next fire / paused on purpose / still red). Do not omit it.
  Treat `kanban-pickup` as critical: if it has no scheduler session or
  `routine-heartbeats` entry within the last 2 hours AND there is any eligible
  `todo` card with `Repo:`/`Base:` and no `BLOCKED:` note, surface this as a
  top routine-health alert. Name the top eligible card(s), the last pickup time,
  and say that the ready queue is not being drained.
- **§🔬 New releases — working well?** Always include. This is distinct from
  §🩺 (did a scheduled fire succeed) and §📦 (ELI5 story of what landed).
  Question: of the things that *newly became true* in the last ~36h, is each
  actually true **on this machine right now**? "CR merged" / "CI green" is not
  the answer. Cap **5** items. Cheap live probes only; do not start apps,
  run full acceptance, or heal (BRIEF is read-only).

  Discover, cheapest first:
  1. Brain closeouts from the last 36h (`brain ask "closeout <YYYYMMDD>"` for
     today and yesterday). Prefer a claimed user-visible capability, skip
     drive-by refactors. Always also `brain get routine-reds-recheck-latest
     --type reference` (paste the table into §🩺).
  2. The latest dated slice in
     `${ROUTINES_HOME:-$HOME/.routines}/memory/last-stack-fleet-performance/memory.md`.
  3. `host-track status` for apps that moved: `host_head` vs the closeout
     merge_oid. Lastgit/main ahead of the live RUN tree is
     `not-on-this-machine-yet`, not working.
  4. If `feature-prove` already wrote PASS today for the same claim, cite that
     PASS instead of re-proving.

  Each item is one line: **claim** · **verdict** · **probe you ran**.
  Verdicts:
  - `working` — live probe matches the claim
  - `not-on-this-machine-yet` — merged upstream; live host_head / RUN file /
    registry TOML does not have it yet (name both refs)
  - `broken` — live machine contradicts the claim (restomp, parse error, last
    harness fire error after the merge). One line of evidence; do not fix.

  Probe examples (pick one per claim): `routines doctor` parse-error count;
  live `~/.routines/registry/<id>.toml` still has the sliced `rrule`;
  `routines list --json` includes an id that had been dropped; last
  `~/.routines/runs/<id>/*/meta.json` outcome *after* the merge; the live
  `prompt_path` file contains a new SOP slug.

  If nothing new landed: one line "no new releases in the window."
- **§🏭 Ship pipeline (North Star → Milestone → PR → shipped).** Always
  include. Primary source: brain **`ship-pipeline-gap-audit-latest`** written
  by the nightly `ship-pipeline-gap-audit` routine. Paste/adapt its
  **one-line health**, ranked gaps (P0/P1 only unless quiet), and "What morning
  think should show Tom" bullets. If the record is missing or older than 36h,
  say so and run a quick `last-stack-ship-pipeline-gap-snapshot --json` (or
  `kanban pickup status --json` + `last-stack-why-stopped --json`) for a
  one-paragraph substitute — do not re-run the full nightly audit. Name any
  process-improvement cards auto-filed overnight.
- **§📦 What shipped overnight (plain English — always include).** This is the
  standing overnight story the human wants every morning (Tom 2026-07-31): not a
  commit wall and not jargon.
  1. **Bottom line** in one breath (speed-ups, safety, cleanup, or quiet).
  2. **2–5 everyday categories** (e.g. filing cabinet/database, to-do board,
     code shelf, backups/safety net, cleanup) — group by *what it means for the
     human*, not by repo. Under each: a few sentences max, **no technical
     terms** (no PR numbers, schema names, latency numbers). Explain like
     they're five: what changed + **what effect they should notice**.
  3. **One-line "effect on the database"** when anything touched the brain /
     board / storage layer (same data vs cheaper writes vs cleaner reads vs
     durability still open). If nothing database-shaped moved, say so.
  4. Optional short BY-PROGRAM bullet skim *after* the ELI5 story — never
     instead of it. If the night was empty: "quiet night" and skip empty
     categories.
  Gather via the morning-digest gather helper + Situations notices + routine
  final words when available; still roll up meaning, not raw commits.

## Setup
- If your shell is sandboxed, prepend `$PATH` on every call so your tools resolve.
- First run a socket-backed narrow board read such as
  `<board CLI> list --column todo --json`. Treat `service_timeout`, "node did not
  respond", or "too many concurrent reads" as busy-node backpressure: STOP,
  report `busy-node skipped morning-sync`, and do not run doctor/init or restart
  anything.
- Snapshot with bounded reads: read `todo`, `doing`, and `review` as sequential
  `<board CLI> list --column <column> --json` calls; use `show` only for the one
  card whose full body you need. Read the brain's goal note, driving index,
  `open-decisions`, `routine-heartbeats`, **`human-gate-audit-latest`**,
  **`ship-pipeline-gap-audit-latest`**, and **`routine-reds-recheck-latest`**
  (if present) as targeted records, one at a time.
- Also inspect your scheduler/session index if available. For Codex Desktop this
  is typically `$CODEX_HOME/session_index.jsonl` or
  `$HOME/.codex/session_index.jsonl`; compare `last-stack kanban-pickup` against
  the hourly cadence. Use this only as read-only evidence for §🩺.

## Deliver
Build the brief per the skeleton, lead with the goal one-liner. Then: print the
full brief (it reaches the human via this task's completion notification), upsert
it to a `morning-sync-brief-latest` note via stdin, and use
`<last-stack>/bin/last-stack-brain-append-heartbeat --line "morning-sync
<ISO-ts> ok <summary>"` to append the typed `routine-heartbeats` line.

End by noting that most things are being driven automatically and the human only
needs to weigh in on §⚠️ or redirect §🚀.

> **Companion interactive mode (optional).** Many fleets pair this read-only BRIEF
> with an interactive WORK mode the human triggers by hand: walk them through the
> §⚠️ decisions one at a time, write each answer to a durable `decisions-log` in
> the brain, and execute it onto the board (clear a gate to `todo`, scope a
> program into a card, or record a hold). That keeps the decision-capture loop ON
> TOP of `program-driver`/`groom-board`/`kanban-pickup` without replacing them.

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
