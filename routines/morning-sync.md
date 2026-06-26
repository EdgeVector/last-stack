---
name: morning-sync
cadence: daily
description: Deliver a daily briefing — progress being driven (§🚀) + the SHORT genuinely-human decision set (§⚠️) + scoping/health/overnight. Read-only; autonomy-first framing.
---

Produce and DELIVER the daily briefing. This is READ-ONLY — do not move cards,
edit gate cards, or run `fkanban-agent`. The only writes are (a) upserting the
brief to a `morning-sync-brief-latest` note in your brain and (b) one heartbeat
line. You start cold with no memory of prior runs.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

> **CRITICAL framing:** the fleet DRIVES autonomously toward the goal; it does NOT
> gate on caution. So this brief is NOT a decision-fatigue queue. Most "gates" are
> autonomous (driven by `program-driver`/`fkanban-agent`) and must NOT be surfaced
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
  `blocked-needs-human` lines. Dedup by slug. Do NOT list dev-enable / security-
  review / design-first cards here — those are being driven. **If §⚠️ is empty,
  say so — that's the goal.**
- **§🧩 Needs scoping** — active programs with no card whose next move is concrete
  but un-carded.
- **§🩺 Routine health** — from your scheduler's last-run timestamps + the
  `routine-heartbeats` note; flag any routine stale-vs-cadence or errored.
- **§📦 Moved overnight** — git activity across your repos in the last 24h, rolled
  up BY PROGRAM (not by individual PR), short.

## Setup
- If your shell is sandboxed, prepend `$PATH` on every call so your tools resolve.
- First run your board health check (`<board CLI> doctor`). Treat a green
  `doctor` as authoritative even when it reports a Unix-socket transport and the
  HTTP endpoint is unavailable; some LastDB/F-Kanban installs intentionally run
  socket-only with HTTP shut down. If `doctor` says the node is unreachable or
  unprovisioned, STOP and report — never restart/kill the process hosting your
  brain/board node.
- Snapshot: `<board CLI> list --json`; the brain's goal note, driving index,
  `open-decisions`, and `routine-heartbeats`.

## Deliver
Build the brief per the skeleton, lead with the goal one-liner. Then: print the
full brief (it reaches the human via this task's completion notification), upsert
it to a `morning-sync-brief-latest` note via stdin, and append `morning-sync
<ISO-ts> ok <summary>` to `routine-heartbeats` (newest on top).

End by noting that most things are being driven automatically and the human only
needs to weigh in on §⚠️ or redirect §🚀.

> **Companion interactive mode (optional).** Many fleets pair this read-only BRIEF
> with an interactive WORK mode the human triggers by hand: walk them through the
> §⚠️ decisions one at a time, write each answer to a durable `decisions-log` in
> the brain, and execute it onto the board (clear a gate to `todo`, scope a
> program into a card, or record a hold). That keeps the decision-capture loop ON
> TOP of `program-driver`/`groom-board`/`fkanban-pickup` without replacing them.
