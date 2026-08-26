# Host memory guards

Last Stack ships three host-side memory jobs next to the primary LastDB
guard. They bound GUI viewers, cargo test binaries, and host pressure. They
do not restart `lastdbd`.

Until this packaging, the scripts lived only in `$HOME/.lastdb/monitoring`
with per-user LaunchAgents. A new Mac or an artifact refresh dropped the
protection. Brain:
`papercut-host-memory-guards-are-unversioned-machine-state`.

## Units

| Job | Script | LaunchAgent | Action | Default limit |
|---|---|---|---|---|
| GUI app guard | `bin/last-stack-gui-app-memory-guard` | `com.edgevector.gui-app-memory-guard` | kill | 8 GiB |
| Cargo testbin guard | `bin/last-stack-testbin-memory-guard` | `com.edgevector.testbin-memory-guard` | kill | 8 GiB |
| Host sentinel | `bin/last-stack-host-memory-sentinel` | `com.edgevector.host-memory-sentinel` | alert only | swap 20 GiB / free 8% |

The primary daemon guard stays in `docs/lastdb-memory-guard.md`. This page
does not change that 16 GiB `phys_footprint` policy.

## Fail-closed matchers

The GUI guard matches the executable path (`ps -o comm=`) against a fixed
allowlist. The default list is Activity Monitor only. A process outside the
list cannot match. Do not add an app without a Tom decision.

The testbin guard matches only cargo deps paths:

- `*/target/*/deps/*`
- `*/debug/deps/*`
- `*/release/deps/*`

`lastdbd`, fold-app, VMs, editors, and agents never match. Both kill guards
also skip any comm that ends in `/lastdbd`.

The sentinel never kills. It pages (`ra notify`) and posts a Situations
notice.

## Install

`setup` calls `bin/last-stack-host-memory-guards-install`. A throwaway
prefix with `LAST_STACK_LAUNCHD_DOMAIN=none` writes the three plists and
does not call `launchctl`.

```bash
LAST_STACK_PUBLIC_ROOT="$HOME/.last-stack" \
  bin/last-stack-host-memory-guards-install install
```

The installer:

- writes `~/Library/LaunchAgents/com.edgevector.{gui-app-memory-guard,testbin-memory-guard,host-memory-sentinel}.plist`
- points `ProgramArguments` at `$HOME/.last-stack/bin/...` (stable public root)
- removes leftover per-user plists for the same three jobs
- does not boot out `com.edgevector.lastdb-memory-guard`
- does not start, stop, or signal the primary `lastdbd`

## Tunables

GUI guard: `GUI_GUARD_LIMIT_MB` (8192), `GUI_GUARD_DRY_RUN`,
`GUI_GUARD_ALLOWLIST`.

Testbin guard: `TESTBIN_RSS_LIMIT_MB` (8192), `TESTBIN_GUARD_DRY_RUN`.

Sentinel: `SENTINEL_SWAP_ALERT_MB` (20480), `SENTINEL_FREE_PCT_ALERT` (8),
`SENTINEL_DRY_RUN`.

Set `*_DRY_RUN=1` to log an over-limit or alert without a kill or a page.

Fixtures: `tests/last-stack-host-memory-guards.sh` (required CI gate).
