# LastDB primary memory guard

`bin/last-stack-lastdb-memory-guard` is the circuit breaker that soft-restarts
the primary `lastdbd` when it holds too much memory. It exists because of the
2026-07-14 failure: cloud-sync `download_entries` ballooned footprint
0.5 GB → 74 GB in ~2 minutes, exhausted swap, and tripped the kernel watchdog
(panic + reboot).

Until this file existed the script lived only at
`$LASTDB_HOME/monitoring/lastdbd-memory-guard.sh`, with no repo of record.

## The gauges

`ps -o rss=` does not show all memory that the process holds. On macOS, it
excludes compressed pages. The daemon uses many compressed pages.

| Gauge | Value on 2026-08-06 | Percent of the old 12 GiB limit |
|---|---|---|
| `ps -o rss=` | 1.47 GiB | 12% |
| `phys_footprint` | 8.75 GiB | 73% |
| `phys_footprint` peak | 11.11 GiB | 92.5% |

macOS jetsam and Activity Monitor use `phys_footprint`. The 2026-07-14 failure
also occurred in this unit. RSS was approximately six times smaller.

The guard reads `phys_footprint` through `proc_pid_rusage` (a direct kernel
syscall), not through this daemon's own `/api/status`. A steady-state cycle
therefore makes zero HTTP calls to the node — before this port, each cycle
cost the node an `/api/status` read (about 242 cold loads). Port of fold
#1908, `scripts/lastdbd/lastdbd-memory-guard.sh` merge 3974e691; see
`design-lastdb-primary-footprint-stays-under-the-guard` clause D.

## The policy

Tom chose `phys_footprint` and a 16 GiB limit on 2026-08-08. The metric and
limit form one policy. See `decision-2026-08-08-memory-guard-footprint-16gib-limit`.

The guard defaults to that policy. It logs both gauges, the footprint source,
and the swap value on each cycle. A normal line has this form:

```
ok pid=73208 metric=footprint enforced_mb=8957 limit_mb=16384 rss_mb=1472 footprint_mb=8957 footprint_source=rusage swap_mb=4096
```

`footprint_source` reads `rss_fallback` on the rare cycle where the rusage
read fails (non-macOS, or the pid raced away) — footprint enforcement then
uses rss for that one cycle rather than skipping it.

The guard does not alert only because swap use is high. macOS swap use alone
does not show available memory capacity.

An operator can set `LASTDBD_GUARD_METRIC=rss` for a compatibility rollback.
This setting restores the blind spot. The guard writes a `blind_spot` warning
if footprint then exceeds the limit.

## Shed before restart

When the enforced gauge trips, the guard no longer jumps straight to
SIGTERM. It first `POST`s `/api/admin/shed` on the primary's own socket and
waits up to `LASTDBD_GUARD_SHED_WAIT_SEC` (default 60s) for footprint to fall
back under the limit:

- If footprint falls, the guard logs `shed_recovered` and returns — no kill.
- If the daemon build predates the shed route, `/api/admin/shed` answers 404;
  the guard logs `shed_unsupported` and moves on. A missing route never fails
  closed.
- If footprint does not fall in time, the guard logs `shed_timeout`, captures
  `vmmap -summary` for post-mortem, then sends SIGTERM with a
  `LASTDBD_GUARD_TERM_WAIT_SEC` (default 60s) clean-shutdown window before
  SIGKILL.

`LASTDBD_GUARD_DRY_RUN=1` logs the restart intent and skips shed, kill, and
kickstart entirely — safe to run against the live primary to sanity-check a
reading.

## Install

```bash
install -m 0755 bin/last-stack-lastdb-memory-guard "$HOME/.last-stack/bin/"
sed "s|/Users/REPLACE|$HOME|g" launchd/com.edgevector.lastdb-memory-guard.plist \
  > "$HOME/Library/LaunchAgents/com.edgevector.lastdb-memory-guard.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.edgevector.lastdb-memory-guard.plist"
```

Installing this agent **replaces** any pre-existing per-user
`*.lastdbd-memory-guard` LaunchAgent running the unversioned copy from
`$LASTDB_HOME/monitoring/`. Bootout the old one first — otherwise both watch the
primary and race on the shared cooldown state file:

```bash
launchctl list | awk '$3 ~ /lastdbd-memory-guard/ { print $3 }'
```

## Tunables

| env | default | meaning |
|---|---|---|
| `LASTDBD_GUARD_METRIC` | `footprint` | gauge that causes the restart (`rss` or `footprint`) |
| `LASTDBD_RSS_LIMIT_MB` | `16384` | limit, in MiB, for the selected gauge |
| `LASTDBD_GUARD_COOLDOWN_SEC` | `120` | minimum seconds between restarts |
| `LASTDBD_PRIMARY_HOME` | `$HOME/.lastdb` | primary home; also locates the socket and logs |
| `LASTDBD_PRIMARY_AGENT_LABEL` | discovered | LaunchAgent to kickstart after a kill |
| `LASTDBD_GUARD_PATH` | hardened list | `PATH` the guard pins for itself under launchd |
| `LASTDBD_GUARD_DRY_RUN` | `0` | log restart intent, skip shed/kill/kickstart |
| `LASTDBD_GUARD_SHED_WAIT_SEC` | `60` | seconds to wait after a shed for footprint to fall |
| `LASTDBD_GUARD_TERM_WAIT_SEC` | `60` | clean-shutdown window after SIGTERM before SIGKILL |

Because footprint comes from `proc_pid_rusage` rather than the socket, an
unreachable node does not blind the footprint reading — only a failed rusage
read (non-macOS, or a pid that raced away) falls back to rss for that cycle.

`--identity` prefers `GET /api/system/boot-identity` with a 1 s budget. On
HTTP 404 only, it reads pid and build from `GET /api/status` and prints
`identity_source=status_fallback`. A down socket, a timeout, or an empty
status body still fails. The guard does not restart the primary for identity.

Fixtures: `tests/last-stack-lastdb-memory-guard.sh` (in the required CI gate).

## Companion host guards

GUI apps, cargo test binaries, and host pressure alerts live in
`docs/host-memory-guards.md`. Those jobs do not restart `lastdbd` and do
not change the 16 GiB footprint policy on this page.
