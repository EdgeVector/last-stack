---
name: kanban-metrics-dashboard
description: |
  Build or refresh an ad-hoc metrics/benchmark view over fkanban or LastDB
  ops data — velocity, throughput, write-timeout benchmarks, board-column
  funnels, per-repo commit activity — as a durable, redeployable Claude
  Artifact instead of a one-off HTML file that gets lost between sessions.
  Use this whenever asked to "build a kanban dashboard", "show board
  velocity", "how fast are we shipping", "benchmark kanban write times",
  "visualize the board", "make a dashboard for X metric", or anything that
  smells like a one-shot ops chart/dashboard for this workspace — even if the
  user doesn't say "dashboard" explicitly. ALWAYS check for a prior instance
  of the same dashboard in fbrain before rebuilding from scratch — this
  workspace has already lost at least one dashboard to being built as an
  ephemeral, non-persisted Artifact with no record of its URL.
---

# kanban-metrics-dashboard

The recurring failure mode this skill exists to prevent: an agent builds a
nice ad-hoc HTML dashboard, it renders great in the session, and then it's
gone — no file committed anywhere, no note of the Artifact URL, so the next
person who wants "that velocity dashboard from earlier" can't find it and
ends up rebuilding it from zero. See fbrain
`papercut-fkanban-updated-at-not-completion-time` for the concrete incident.

## Before building anything

1. `fbrain_search` for the metric you're about to build (e.g. "kanban
   velocity dashboard", "kanban write timeout benchmark"). If a
   `reference`-type record already exists with a live Artifact URL, that's
   your dashboard — **redeploy to that same URL** (pass `url:` to the
   Artifact tool) rather than minting a new one. Read the record's "why this
   metric, not that one" reasoning too; it usually encodes a real constraint
   (see the data-source note below) that you'd otherwise rediscover the hard
   way.
2. If no prior record exists, you're building the first version — plan to
   create the fbrain reference record in step 4 so the *next* request finds
   it.

## Data sources — use the honest signal, not the naive one

fkanban's own timestamps are lossy: `updated_at` gets stomped by every daily
groom sweep, so it is NOT a reliable completion-time signal (only a small
fraction of `done` cards carry a real `done_at` — see
`papercut-fkanban-updated-at-not-completion-time`). Until that's fixed
upstream, prefer:
- **Velocity / throughput**: commit-count-on-main per day per repo
  (`git log origin/main --since="21 days ago" --no-merges --date=short`) as
  the drain-rate proxy, across whichever repos are relevant
  (fold, fbrain, fkanban, exemem-infra, exemem-workspace, last-stack, lastgit
  is a reasonable default set) — NOT `fkanban list` completion timestamps.
- **Board-state snapshot** (funnel by column, WIP, backlog size): `fkanban
  list --json --all` is fine for a point-in-time count — the timestamp
  unreliability only bites when you need *when* something finished.
- **Perf benchmarks** (write timeouts, query latency): measure live against
  the actual node/socket you're benchmarking; don't reuse cached numbers from
  a previous run without re-timestamping them.

## Build

Use the `Artifact` tool (self-contained HTML, inline CSS/JS, no external
requests — see its own guidance for constraints). Keep it a single static
snapshot unless the user specifically wants live-refreshing data; a dashboard
that silently goes stale without saying so is worse than a clearly-dated
snapshot.

## After building — persist it, don't let it evaporate

Write (or update) an fbrain `reference` record, tagged with the relevant
subsystem (e.g. `fkanban`, `lastdb`), recording:
- the live Artifact URL,
- exactly what it shows and over what window,
- the data source and why (especially any "we use X instead of the naive Y
  because Z" reasoning — that's the part someone would otherwise have to
  rediscover),
- the refresh recipe (the exact commands to regenerate the numbers).

On a refresh request, redeploy to the **same** Artifact URL (same file path,
Artifact tool's `url:` param) rather than minting a new one, and update the
fbrain record's body/timestamp in place — don't create a second reference
record for the same dashboard.
