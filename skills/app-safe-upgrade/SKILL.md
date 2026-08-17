---
name: app-safe-upgrade
description: |
  REQUIRED path for upgrading any installed EdgeVector app (kanban, brain,
  situations, last-stack, search, …). Never flip ~/.local/bin or host-track
  current onto a new version first. Probe the candidate tree, then activate
  only on GREEN. LastDB Mini is the one exception: use lastdb-safe-upgrade.
  Use when asked to "upgrade kanban", "upgrade brain", "refresh host-track",
  "safe upgrade this app", "install the new version", or whenever an agent
  would otherwise host-track refresh / brew upgrade / relink PATH blindly.
---

# app-safe-upgrade — canary soak; never make live the first test

The live install is what agents and Tom run. A one-shot `--help` (or even one
`kanban list`) is not enough — LastDB's 0.23.1 latency and the 2026-08-05
write-path regression both passed a single correctness probe. **The safe
upgrade is a canary soak:** park the candidate, keep PATH on last-known-good,
re-run the app's probes over a window, promote only if it stays GREEN.

LastDB Mini stays on `lastdb-safe-upgrade` (24h soak + CoW). Everything else
goes through Host Track.

## Do this

```bash
# Park the new tree as canary (PATH unchanged after GREEN probe)
host-track refresh <app>

# Same clock as the 20-minute LaunchAgent (refresh --all also soak-watches)
host-track soak-watch <app>
host-track soak-watch --all

# Tom wants it on PATH now (still requires GREEN probe)
host-track refresh --activate <app>

# Roll back last activation
host-track rollback <app>
```

`host-track refresh` now:

1. Materializes the candidate under `versions/<digest>` (current unchanged)
2. Runs `post_install` on that tree when the app needs it
3. Runs `safe_upgrade.probes` from the **new** tree
4. Optionally times the last probe vs current (brain / kanban / situations)
5. **Parks `canary`** when `soak_hours > 0` and a live current exists
6. `soak-watch` re-probes; RED leaves current; GREEN + elapsed → flip PATH
7. last-stack sets `soak_hours: 0` (it is the soak runner; probe-then-activate)

## Which command is which

| What Tom said | App name | Command |
|---|---|---|
| new kanban / fkanban | `kanban` | `host-track refresh kanban` then `soak-watch` |
| new brain CLI | `brain` | `host-track refresh brain` then `soak-watch` |
| new last-stack / skills | `last-stack` | `host-track refresh last-stack` (no soak) |
| new situations / routines / search / … | that registry name | `host-track refresh` then `soak-watch` |
| new LastDB Mini / lastdbd | — | **`lastdb-safe-upgrade` only** |

`host-track refresh lastdb` is disabled on purpose.

## Reading the verdict

| Output | Meaning | Action |
|---|---|---|
| `probe GREEN` then `canary parked` | Candidate is soaking; PATH still old | Wait for soak-watch, or `--activate` |
| `soak pending` | Still inside the window and still GREEN | Leave it |
| `soak GREEN` then `activating` | Window passed; live flipped | Done |
| `probe GREEN` then `installed …` | First install, last-stack, or `--activate` | Done |
| `probe RED; refusing cutover` | Candidate failed a declared probe | **Do not** skip-probe; file a release-blocker |
| `already current` | Live matches the channel | Nothing to do |
| `deployment-only` | LastDB Mini | Use `lastdb-safe-upgrade` |

## Never

- `host-track refresh` with `HOST_TRACK_PROBE_SKIP=1` unless Tom said to
- Relink `~/.local/bin/<cmd>` onto a worktree or a staged version by hand
- `brew upgrade` an app that Host Track owns
- Treat `kanban --help` / `brain --help` as enough proof for those two — the
  registry probes a live `kanban list` / `brain get`
- Upgrade LastDB Mini through this skill

## Rollback

```bash
host-track rollback kanban
host-track rollback brain
kanban list --column todo
brain get sop-edgevector-portals
```

## Adding an app

An artifact app without `safe_upgrade.probes` fails `host-track validate-registry`.
Declare at least one argv relative to the version tree (`bin/…` or `dist/…`).
Use `post_install_phase: after-cutover` only when the hook rewrites live links
(last-stack `setup`). Default is `before-probe`.
