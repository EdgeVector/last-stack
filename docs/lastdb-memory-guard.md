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

The daemon publishes `phys_footprint_bytes` on `/api/status`. The guard reads
this value from the Unix socket. It does not require elevated privileges.

## The policy

Tom chose `phys_footprint` and a 16 GiB limit on 2026-08-08. The metric and
limit form one policy. See `decision-2026-08-08-memory-guard-footprint-16gib-limit`.

The guard defaults to that policy. It logs both gauges and the swap value on
each cycle. A normal line has this form:

```
ok pid=73208 metric=footprint enforced_mb=8957 limit_mb=16384 rss_mb=1472 footprint_mb=8957 peak_mb=12544 swap_mb=4096
```

The guard does not alert only because swap use is high. macOS swap use alone
does not show available memory capacity.

An operator can set `LASTDBD_GUARD_METRIC=rss` for a compatibility rollback.
This setting restores the blind spot. The guard writes a `blind_spot` warning
if footprint then exceeds the limit.

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

If the node is unavailable, the guard does not use RSS as a substitute for
footprint. It writes a warning and takes no action for that cycle.

Fixtures: `tests/last-stack-lastdb-memory-guard.sh` (in the required CI gate).

## Companion host guards

GUI apps, cargo test binaries, and host pressure alerts live in
`docs/host-memory-guards.md`. Those jobs do not restart `lastdbd` and do
not change the 16 GiB footprint policy on this page.
