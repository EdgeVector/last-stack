# LastDB primary memory guard

`bin/last-stack-lastdb-memory-guard` is the circuit breaker that soft-restarts
the primary `lastdbd` when it holds too much memory. It exists because of the
2026-07-14 failure: cloud-sync `download_entries` ballooned footprint
0.5 GB → 74 GB in ~2 minutes, exhausted swap, and tripped the kernel watchdog
(panic + reboot).

Until this file existed the script lived only at
`$LASTDB_HOME/monitoring/lastdbd-memory-guard.sh`, with no repo of record.

## The two gauges

`ps -o rss=` is not the memory this process holds. On macOS it excludes
compressed pages, and the daemon lives mostly there. Measured on the live
primary, 2026-08-06:

| gauge | reading | % of the 12 GiB ceiling |
|---|---|---|
| `ps -o rss=` (what the guard enforces) | 1.47 GiB | 12% |
| `phys_footprint` | 8.75 GiB | 73% |
| `phys_footprint` peak | 11.11 GiB | **92.5%** |

`phys_footprint` is the gauge macOS jetsam and Activity Monitor use, and the
unit the 2026-07-14 panic happened in. The guard has been reading a number
~6x smaller than the one that kills the machine, so it cannot fire until true
footprint is ~6.7x the limit.

The daemon already computes and publishes `phys_footprint_bytes` on
`/api/status`, so the guard asks the node over its own socket rather than
shelling out to `vmmap`/`footprint`, which need elevated privileges.

## Why the metric did not simply get swapped

Enforcing on footprint takes the margin from ~8.6x to ~1.4x, on a
process-killer aimed at the primary brain. **The metric and the limit have to
be chosen together**, and that is a human call — see the kanban card
`lastdb-memory-guard-metric-is-rss-not-footprint`.

So the script measures footprint always and logs both gauges every cycle, but
enforces on `LASTDBD_GUARD_METRIC`, which defaults to `rss` — today's behaviour,
unchanged. Every cycle now emits a line like:

```
ok pid=73208 metric=rss enforced_mb=1472 limit_mb=12288 rss_mb=1472 footprint_mb=8957 peak_mb=11372 swap_mb=4096
```

and when real usage crosses the ceiling while the enforced gauge has not:

```
WARN blind_spot pid=… footprint_mb=12401 >= limit_mb=12288 but enforcing on rss_mb=1502 — guard will NOT fire
```

That WARN is the line to alert on while the policy is undecided, and the
`footprint_mb` series is the evidence needed to pick a limit.

## Choosing the policy

One of:

- **raise `LASTDBD_RSS_LIMIT_MB`** to fit a ~9 GiB steady state with headroom,
  then set `LASTDBD_GUARD_METRIC=footprint`;
- **lower the charged budgets** (`LASTDB_HASH_GROUP_WARM_BYTES=4 GiB` +
  resident graph 2 GiB) so steady-state footprint drops, then enforce on
  footprint at the current ceiling;
- **accept restarts at the current ceiling** — enforce on footprint at
  12,288 MB, ~1.4x over observed steady state.

Whatever is chosen, the guard's threshold and the node's own
`memory_budget.rs` projection should agree; today they disagree by 6.7x and
nothing reconciles them.

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
| `LASTDBD_GUARD_METRIC` | `rss` | which gauge fires the restart (`rss` \| `footprint`) |
| `LASTDBD_RSS_LIMIT_MB` | `6144` | ceiling, in MB, for the enforced gauge |
| `LASTDBD_SWAP_WARN_MB` | `20480` | log a warning above this much system swap |
| `LASTDBD_GUARD_COOLDOWN_SEC` | `120` | minimum seconds between restarts |
| `LASTDBD_PRIMARY_HOME` | `$HOME/.lastdb` | primary home; also locates the socket and logs |
| `LASTDBD_PRIMARY_AGENT_LABEL` | discovered | LaunchAgent to kickstart after a kill |
| `LASTDBD_GUARD_PATH` | hardened list | `PATH` the guard pins for itself under launchd |

Under `LASTDBD_GUARD_METRIC=footprint` the guard **declines to enforce** for a
cycle if the node is unreachable, rather than falling back to `rss` — a silent
fallback would restore the 6.7x blind spot the policy was chosen to close.

Fixtures: `tests/last-stack-lastdb-memory-guard.sh` (in the required CI gate).
