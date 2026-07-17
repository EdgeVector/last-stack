---
name: brain-doctor
description: |
  Read-only triage of the LastDB brain (Tom's primary brain/kanban
  daily-driver node — the desktop fold-app process or Mini daemon, reached over
  the Unix socket ~/.lastdb/data/folddb.sock, also served on the legacy
  ~/.folddb path)
  when it's wedged, slow, or down. Bundles the hand-run recipe
  that recurs on every "is kanban down", "is the brain wedged", "why is my
  computer so slow", "brain/kanban won't respond", or "LastDB couldn't take
  over" incident: distinguishes a full sled-IO deadlock from the partial
  write-path stall, finds duplicate launchd/brew supervisors, catches a stale
  ~/.folddb/port breadcrumb, and classifies orphan lastdb_server/folddb_server /
  run.sh / kanban-hook procs vs the real brain. Use when the user (or a routine) reports
  the brain/board/brain unresponsive or slow, or says "run brain-doctor",
  "diagnose the brain", "check the brain socket". This is the DIAGNOSE-FIRST companion to
  machine-hygiene (which does the cleanup/writes); brain-doctor only reads and
  prints recommended recovery commands — it never kills, restarts, or writes.
---

# brain-doctor — LastDB socket triage

The brain is Tom's primary node — `brain` and `kanban` both run on it. It is the
desktop **`fold-app`** process, reached over the **Unix socket
`~/.lastdb/data/folddb.sock`** (the same node is also served on the legacy
`~/.folddb/data/folddb.sock` path — both return HTTP 200; the legacy local TCP
endpoint is shut down). When it stalls, the board and the knowledge base both go
dark. This skill codifies the triage recipe that was previously re-derived by
hand from 5+ scattered memory notes on every incident.

## Run it

```bash
bash ~/.claude/skills/brain-doctor/brain-doctor.sh                          # primary brain socket
bash ~/.claude/skills/brain-doctor/brain-doctor.sh /tmp/dev-node/folddb.sock  # an ephemeral dogfood node's socket
```

Exit code: `0` healthy · `1` degraded (drift / partial stall) · `2` wedged
(full deadlock) · `3` down (no socket).

It is **strictly read-only** — it never kills, restarts, writes a file, or
stashes. It prints the exact recommended recovery command for a human (or a
supervised session) to run. That honors the standing rule: **never kill the
brain unattended; surface, don't act.**

## Situations notices FIRST (before framing an incident)

Before treating flapping / timeouts / busy-node as a new outage, check the
non-blocking agent-impact feed:

```bash
situations notices --since 1h
# especially: --system lastdbd  or  --system last-stack
```

`brain-doctor.sh` also prints a **0. Recent Situations notices** section when
the CLI is available. A matching notice (LastDB upgrade, Last Stack upgrade,
cutover) means: **expected fallout**, not a new P0 — wait out the notice window
before kill/restart recommendations.

## Request ops — name the load (before "wedged")

Slow ≠ dead. Before framing a wedge, run:

```bash
lastdb status    # RSS/CPU/QoS + short request-ops summary
lastdb ops       # worst clients / kinds / schemas by total time and count
```

This is Mini's in-process per-request ranking (`status.request_ops`). Clients
self-identify via `X-LastDB-Client`. Full playbook:
`brain get sop-lastdb-request-ops-telemetry --type sop`. Use it to fix or
throttle the top client — do **not** restart primary `lastdbd` for load alone.

## Reading the output / acting on it

The script checks, in order: (0) recent Situations notices, (1) socket + LastDB server PID + uptime/CPU,
(2) processes holding the socket (the do-not-kill signal — live client = real
brain), (3) responsiveness probe over the socket, (4) duplicate supervisors,
(5) vestigial port breadcrumb, (6) orphan folddb procs, (7) disk. Then a verdict.

Key triage decisions it encodes:

- **WEDGED (full deadlock):** `GET /` over the socket times out **and** CPU ~0%.
  A plain `brew services restart` / launchctl restart looks successful but leaves
  the SIGTERM-deaf PID holding the socket. You must `kill -9 <pid>` (confirm first with
  `sample <pid> 5` showing parked sled `apply_batch`/`make_stable` threads);
  launchd KeepAlive respawns a healthy PID. **Re-run brain-doctor afterward to
  confirm the PID changed.**
- **DEGRADED (partial write-path stall):** reads + tiny writes are instant but
  real-sized writes hang >300s (CPU oscillates). A **graceful**
  `launchctl kickstart -k gui/$(id -u)/com.folddb.daemon` clears it — `kill -9`
  is NOT needed here. This is uptime-accumulated embedding-path degradation, not
  data scaling: the same big writes succeed right after restart.
- **Duplicate supervisor / stale breadcrumb:** the "LastDB couldn't take over"
  class. Fix by removing the loser supervisor and/or correcting `~/.folddb/port`
  (commands are printed). Since fold#812 the breadcrumb is no longer load-bearing
  for takeover, but it's still drift worth clearing.
- **Orphans:** any folddb_server NOT serving the primary socket whose cwd is a **deleted worktree**,
  plus idle `run.sh --local` harnesses on temp `--home` and hours-old stuck
  `kanban hooks ingest` procs, are safe sweep candidates — but verify cwd is gone
  and no live client/builder first, and surface rather than kill in unattended runs.

## When NOT to use this

- For actual **cleanup / disk reclaim / worktree pruning** (writes), use the
  `machine-hygiene` skill — brain-doctor only diagnoses.
- It does not touch ephemeral dogfood nodes' teardown — see
  `~/.claude/scheduled-tasks/_lib/teardown-stale-dogfood-worktrees.sh`.

## Background (memory cross-refs)

Historical Brain records still use old slugs:
`project_folddb_brain_wedged_2026_06_13` (full vs partial wedge recipe),
`project_folddb_desktop_takeover_dup_supervisor` (dup supervisor + stale port),
`feedback_dont_kill_primary_folddb_server` (live-brain protection),
`project_kanban_orphan_folddb_server` (orphan sweep classifier),
`project_cli_status_flake_fixed` / `project_folddb_cli_sled_lock_slow` (slow ≠ wedged).
