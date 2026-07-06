---
name: brain-doctor
description: Read-only triage of Tom's primary LastDB/F-Brain/F-Kanban node over the Unix socket when it is wedged, slow, down, blank in the GUI, or the socket vanishes after unlock. Use when the user says run brain-doctor, diagnose the brain, check the brain socket, fbrain/fkanban will not respond, LastDB is blank, or LastDB will not come up. Distinguishes Browse N+1 file-descriptor exhaustion, sled deadlocks, partial write stalls, duplicate supervisors, stale port breadcrumbs, and orphans. Diagnose-first; never kills, restarts, or writes.
---

# brain-doctor — folddb socket triage

The brain is Tom's primary node — `fbrain` and `fkanban` both run on it, reached
over the **Unix socket `~/.folddb/data/folddb.sock`** (the legacy local TCP
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

## Diagnostic posture

Do not relaunch, rebuild, reinstall, or restart as the first diagnostic move.
The recent LastDB blank-window/socket-vanish incidents got worse when agents
restarted early: reload destroyed evidence, overlapped launch supervisors, and
made symptoms look like keyring, stale binary, or daemon takeover bugs.

Observe first, then perform at most one clean supervised launch after the cause
is classified.

## Reading the output / acting on it

The script checks, in order: (1) socket + folddb_server PID + uptime/CPU,
(2) processes holding the socket (the do-not-kill signal — live client = real
brain), (3) responsiveness probe over the socket, (4) duplicate supervisors,
(5) vestigial port breadcrumb, (6) orphan folddb procs, (7) disk. Then a verdict.

Key triage decisions it encodes:

- **Blank UI / vanished Unix socket / "network connection failed" after unlock:**
  suspect file-descriptor exhaustion before keyring, stale frontend, or stale
  binary. Check the node PID and compare open fds with the GUI process limit:
  ```bash
  pid=$(pgrep -fn 'folddb|lastdb|fold_db_node|fold-app' || true)
  test -n "$pid" && lsof -p "$pid" | wc -l
  launchctl limit maxfiles
  ```
  If the process looks alive but the owner socket vanished, log tails mention
  `Too many open files`, or fd count is near the soft limit, classify this as
  the Browse N+1 / fd-exhaustion class. Capture `lsof`, socket list, and logs
  before any restart.
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
- **Duplicate supervisor / stale breadcrumb:** the "FoldDB couldn't take over"
  class. Fix by removing the loser supervisor and/or correcting `~/.folddb/port`
  (commands are printed). Since fold#812 the breadcrumb is no longer load-bearing
  for takeover, but it's still drift worth clearing.
- **Orphans:** any folddb_server NOT serving the primary socket whose cwd is a **deleted worktree**,
  plus idle `run.sh --local` harnesses on temp `--home` and hours-old stuck
  `kanban hooks ingest` procs, are safe sweep candidates — but verify cwd is gone
  and no live client/builder first, and surface rather than kill in unattended runs.
- **Keyring-looking failures:** only treat as keyring recovery after observing
  a concrete keyring/decrypt error. Primary-brain keyring recovery is Tom-gated;
  do not rotate credentials, clear keychains, or run destructive recovery
  unattended.

## When NOT to use this

- For actual **cleanup / disk reclaim / worktree pruning** (writes), use the
  `machine-hygiene` skill — brain-doctor only diagnoses.
- It does not touch ephemeral dogfood nodes' teardown — see
  `~/.claude/scheduled-tasks/_lib/teardown-stale-dogfood-worktrees.sh`.

## Background (memory cross-refs)

`project_folddb_brain_wedged_2026_06_13` (full vs partial wedge recipe),
`project_folddb_desktop_takeover_dup_supervisor` (dup supervisor + stale port),
`feedback_dont_kill_primary_folddb_server` (live-brain protection),
`project_kanban_orphan_folddb_server` (orphan sweep classifier),
`project_cli_status_flake_fixed` / `project_folddb_cli_sled_lock_slow` (slow ≠ wedged),
`retro-node-wont-come-up-misdiagnosis-loops-2026-06-29-07-01`
(Browse N+1 fd exhaustion, restart-first amplified the incident).
