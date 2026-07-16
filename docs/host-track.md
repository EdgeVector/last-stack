# Host Track

`host-track` is the shared agent-facing command for checking and refreshing
durable host installs. It keeps agents pointed at known host tracks instead of
ad hoc worktrees under `~/code/edgevector`.

## Commands

```bash
host-track status --json
host-track status lastgit
host-track which lastgit
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
- `gate_head`
- `exec_path`
- `kind`
- `stale`
- `stamp`
- `refresh`
- `notes`

Refresh stamps are written under `~/.host-track/stamps/<app>.json`, or under
`HOST_TRACK_STAMP_DIR` when set.

## Registry Kinds

- `A compile`: build and install a binary, such as `lastgit`.
- `B checkout-shim`: fast-forward a host checkout and expose a PATH shim.
- `C skill-pack`: refresh a skill-pack checkout and rerun its setup.
- `D daemon/cloud`: intentionally out of scope for this driver until a concrete
  app opts in.

The initial registry includes real entries for `lastgit` and `last-stack`, plus
placeholder B-kind entries for `brain`, `situations`, and `kanban`.
