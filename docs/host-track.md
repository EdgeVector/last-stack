# Host Track

`host-track` is the shared agent-facing command for checking and refreshing
durable host installs. It keeps agents pointed at known host tracks instead of
ad hoc worktrees under `~/code/edgevector`.

## Commands

```bash
host-track status --json
host-track status lastgit
host-track which lastgit
host-track which last-stack --json
host-track check lastgit
host-track refresh lastgit
host-track refresh --force last-stack
```

The default registry lives at `config/host-track/apps.json`. Tests and local
experiments can point at another registry with `HOST_TRACK_REGISTRY`.

## Status Shape

Each status record reports:

- `app`
- `command`
- `gate`
- `gate_main`
- `host_track`
- `host_head`
- `host_head_short`
- `version`
- `gate_head`
- `exec_path`
- `kind`
- `stale`
- `stamp`
- `refresh`
- `notes`

Refresh stamps are written under `~/.host-track/stamps/<app>.json`, or under
`HOST_TRACK_STAMP_DIR` when set.

## Refresh Agent

`./setup` installs a user LaunchAgent named
`com.edgevector.host-track-refresh`. The plist lives at
`~/.last-stack/launchd/com.edgevector.host-track-refresh.plist` and runs:

```bash
~/.local/bin/host-track refresh --all
```

The safety poll runs every 20 minutes. When the registry has Forgejo-gated apps
with local host checkouts, setup also adds existing `<git-dir>/FETCH_HEAD` paths
as optional `WatchPaths`, so fetch activity can trigger the same refresh command
without one plist per app. The plist sets a tool-friendly PATH including
`~/.local/bin`, `~/.bun/bin`, Homebrew, and system directories.

Uninstall removes the plist and boots out the loaded service:

```bash
~/.last-stack/setup --uninstall
```

## Registry Kinds

- `A compile`: build and install a binary, such as `lastgit`.
- `B checkout-shim`: fast-forward a host checkout and expose a PATH shim.
- `C skill-pack`: refresh a skill-pack checkout and rerun its setup.
- `D daemon/cloud`: intentionally out of scope for this driver until a concrete
  app opts in.

The registry includes real entries for `lastgit`, `last-stack`, and `kanban`,
plus placeholder B-kind entries for `brain` and `situations`.
