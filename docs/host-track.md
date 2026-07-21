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
host-track install --channel candidate my-app
host-track rollback my-app
```

The default registry lives at `config/host-track/apps.json`. Tests and local
experiments can point at another registry with `HOST_TRACK_REGISTRY`.

## Artifact installs

New entries in the default registry inherit `install_mode: artifact`. Existing
checkout-backed apps carry an explicit `install_mode: checkout` until their
producer and compatibility proof are migrated. An artifact entry can set:

```json
{
  "app": "my-app",
  "command": "my-app",
  "artifact_app": "my-app",
  "artifact_channel": "stable",
  "install_root": "$HOME/.host-track/apps/my-app",
  "links": [
    {"source": "bin/my-app", "target": "$HOME/.local/bin/my-app"}
  ]
}
```

`host-track install` asks LastGit to resolve and verify the promoted channel,
verifies every blob again while copying it, installs under the immutable
`versions/<manifest-digest>` directory, and atomically switches `current`.
The displaced version remains at `previous` for `host-track rollback`.
`host-track check` verifies the active payload hashes as well as freshness.
It refuses to replace a non-symlink command target.

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
- `install_mode`
- `stale`
- `stamp`
- `refresh`
- `notes`

Artifact-backed records also report `artifact_app`, `artifact_channel`,
`artifact_root`, `install_root`, `manifest_digest`, and
`channel_manifest_digest`.

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

The registry includes real entries for `lastgit`, `last-stack`, `situations`,
and `kanban`, plus a placeholder B-kind entry for `brain`.
