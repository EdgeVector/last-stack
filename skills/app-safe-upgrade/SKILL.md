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

# app-safe-upgrade — probe the candidate; never make live the first test

The live install is what agents and Tom run. A broken kanban or brain is a
board/brain outage. **Standing rule:** every app upgrade uses this path so
the new tree fails on a probe, not on the PATH Tom already has.

LastDB Mini (the database, not the `brain` CLI) stays on
`lastdb-safe-upgrade`. Everything else goes through Host Track.

## Do this

```bash
# One app (promotes green+published main, stages, probes, then flips current)
host-track refresh <app>

# See what would change
host-track status <app>
host-track status --stale

# Fleet of local CLIs
last-stack-safe-upgrade-all-local

# Roll back last activation
host-track rollback <app>
```

`host-track refresh` now:

1. Materializes the candidate under `versions/<digest>` (current unchanged)
2. Runs `post_install` on that tree when the app needs it (bun install, etc.)
3. Runs the app's `safe_upgrade.probes` from the **new** tree
4. Optionally times the last probe vs the current tree (brain / kanban / situations)
5. Flips `current` + PATH links only on GREEN
6. Hash-verifies the active tree and stamps; RED rolls current back if it had moved

## Which command is which

| What Tom said | App name | Command |
|---|---|---|
| new kanban / fkanban | `kanban` | `host-track refresh kanban` |
| new brain CLI | `brain` | `host-track refresh brain` |
| new last-stack / skills | `last-stack` | `host-track refresh last-stack` |
| new situations / routines / search / … | that registry name | `host-track refresh <app>` |
| new LastDB Mini / lastdbd | — | **`lastdb-safe-upgrade` only** |

`host-track refresh lastdb` is disabled on purpose.

## Reading the verdict

| Output | Meaning | Action |
|---|---|---|
| `probe GREEN` then `installed …` | Candidate served real verbs; live flipped | Done |
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
