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
host-track refresh --all
host-track refresh --force last-stack
host-track install --channel candidate my-app
host-track rollback my-app
```

The default registry lives at `config/host-track/apps.json`. Tests and local
experiments can point at another registry with `HOST_TRACK_REGISTRY`.

## Artifact installs

New entries in the default registry inherit `install_mode: artifact`. Existing
checkout-backed apps carry an explicit `install_mode: checkout` until their
producer and compatibility proof are migrated. Checkout-backed apps must carry
an `artifact_exemption` with `kind` set to `deployment-only` or
`bootstrap-recovery`, plus an `owner` and `rationale`, so continuous dogfood can
separate intentional exceptions from drift. An artifact entry can set:

```json
{
  "app": "my-app",
  "command": "my-app",
  "artifact_app": "my-app",
  "artifact_channel": "stable",
  "install_root": "$HOME/.host-track/apps/my-app",
  "post_install": "$HOME/.host-track/apps/my-app/current/bin/post-install",
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
When configured, `post_install` runs after activation and after rollback with
`HOST_TRACK_APP`, `HOST_TRACK_INSTALL_ROOT`, and
`HOST_TRACK_MANIFEST_DIGEST` in its environment. A failed hook leaves the app
stale (no new stamp), so the refresh agent retries instead of claiming success.

### Last Stack one rule (artifact is the only runtime)

**Runtime install = Host Track CI artifact only. Never a place you develop.**

| Role | Path | Mutable? |
|------|------|----------|
| **Run** | `~/.local/state/last-stack/artifacts/versions/<digest>` via `current` | No — replace whole version |
| **Compat paths** | `~/.last-stack/{bin,skills,routines,...}` -> `~/.local/state/last-stack/artifacts/current/...` | Symlinks only |
| **Dev** | Isolated worktree of `EdgeVector/last-stack` | Yes — normal CR flow |
| **State** | logs, proofs, dogfood, stamps under `~/.local/state` / install state dirs | Yes |

Last Stack artifacts install below `~/.local/state/last-stack/artifacts` so
verified versions, stages, and rollback state do not dirty the `~/.last-stack`
owner mirror. The artifact `post_install` runs `setup`, and artifact-mode setup
runs `last-stack-activate-artifact-layout`, which:

1. Moves any leftover real code trees aside (recovery under
   `~/.local/state/last-stack/layout-backups`)
2. Symlinks stable paths (`bin`, `skills`, `routines`, `config`, ...) at
   `~/.local/state/last-stack/artifacts/current/...`
3. Freezes the active version tree (`chmod a-w`) so agents cannot hand-edit
   through the compatibility links
4. Re-runs `./setup` from the artifact (skill links, host-track refresh agent)

Manual / dry-run:

```bash
~/.local/state/last-stack/artifacts/current/bin/last-stack-activate-artifact-layout --dry-run
~/.local/state/last-stack/artifacts/current/bin/last-stack-activate-artifact-layout
```

The migration moves displaced code into a timestamped directory under
`~/.local/state/last-stack/layout-backups`; it leaves `.git`, `launchd`, logs,
proofs, and other local state untouched. By default the activator skips a git
worktree compatibility root instead of replacing tracked source paths with
artifact links; use a non-git compatibility root for that layout. Artifact
installs use the Host Track refresh agent, so setup removes the retired Git
self-upgrade LaunchAgent.

**Upgrade:** `host-track refresh last-stack` (or the host-track refresh
LaunchAgent). Git `self-upgrade` / dirty-tree repair is a no-op on artifact
runtime and must not be used to “heal” agent edits.

**Develop:** worktrees only. Never `Write` product files under `~/.last-stack`.
Runtime artifact state is intentionally outside the owner mirror so it cannot
dirty that checkout.

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

## Continuous Artifact Invariant

`bin/last-stack-host-track-artifact-invariant` is the dogfood-registry recipe
entry point for Host Track artifact freshness. It inventories every registered
app, rejects non-artifact installs without a machine-readable exemption, checks
the selected channel and `stale:false`, verifies exact manifest source
provenance, rehashes active payload files, confirms command paths resolve inside
immutable `versions/<manifest>` directories, compares paired `lastdb` and
`lastdbd` bundle identity when both are registered, and proves rollback state by
inspecting the `previous` symlink without switching it.

```bash
bin/last-stack-host-track-artifact-invariant
bin/last-stack-host-track-artifact-invariant --json
HOST_TRACK_REGISTRY=/path/to/apps.json bin/last-stack-host-track-artifact-invariant
```

`bin/last-stack-artifact-host-track-proof` is the terminal proof wrapper for
the artifact-driven registry cutover. It runs Host Track status, the artifact
invariant, and `host-track check` for every registered app. On success it writes
`PASS` to
`~/.last-stack/feature-proofs/artifact-driven-host-track-registry-cutover.md`.
Run it after refreshing the registry from promoted artifacts:

```bash
host-track refresh --all
bin/last-stack-artifact-host-track-proof
```

Refresh stamps are written under `~/.host-track/stamps/<app>.json`, or under
`HOST_TRACK_STAMP_DIR` when set.

## Post-merge auto safe-upgrade (completer companion)

After a LastGit CR **merges to main**, the local forge supervisor can run
install-side safe-upgrade so PATH tracks main without stuffing that into CI.

- **Script:** `last-stack-post-merge-safe-upgrade --all`
- **Supervised by:** lastgit `.lastgit/forge-run.sh` (same process as CI watch +
  Discord notify) when the binary is on PATH
- **Detects merges** like `notify-discord.sh`: fleet open-CR index → open→gone →
  `cr view` → if `state=merged` and base is `main` and repo is mapped → upgrade
- **Mapped apps:** brain, situations, fkanban/kanban, routines, lastsecrets,
  configurations
- **Failure:** log + retry (max 3); **does not unmerge**; operator can run
  `last-stack-safe-upgrade-cli <app>` manually
- **State:** `~/.lastgit/post-merge-safe-upgrade/`
- **Disable:** `LAST_STACK_POST_MERGE_DISABLE=1` on the forge LaunchAgent env

```bash
# map
last-stack-post-merge-safe-upgrade --map
# one poll pass (seed or catch-up)
last-stack-post-merge-safe-upgrade --once --all
```

## Local safe-upgrade (no cloud) — agent CLIs

For machine-local CI (Forgejo/LastGit on this Mac), you do **not** need to push
artifacts to Exemem/R2. Build a new immutable version, smoke it, then flip
`current` while keeping `previous` for rollback.

Layout (same shape as artifact installs):

```text
~/.host-track/apps/<app>/
  versions/<git-sha>/    # immutable built tree
  current  -> versions/<sha>
  previous -> versions/<old-sha>
~/.local/bin/<cmd> -> …/current/bin/<cmd>
```

### Tools

```bash
# Build from lastgit/bare cache tip, smoke, activate (PATH flip only after smoke)
last-stack-safe-upgrade-cli brain

# CI last step on a green main checkout (all local):
last-stack-safe-upgrade-cli brain --source-dir "$PWD"

# Status / rollback
last-stack-safe-activate-cli status --app brain
last-stack-safe-activate-cli rollback --app brain \
  --link "bin/brain:$HOME/.local/bin/brain"
```

Safe properties:

1. Smoke runs with `PATH=<new-version>/bin:…` **before** `current` moves.
2. `previous` always retains the last good version after a successful flip.
3. Install trees are not work surfaces — develop via portals + `wt start`.

`host-track refresh <app>` for local-safe apps calls
`last-stack-refresh-local-safe <app>` → `last-stack-safe-upgrade-cli <app>`.
LaunchAgent `com.edgevector.host-track-refresh` runs `host-track refresh --all`.

**Local-safe apps (2026-07-22):** brain, situations, kanban/fkanban (shared
install), routines, lastsecrets, configurations.

```bash
# Upgrade every local-safe CLI
last-stack-safe-upgrade-all-local

# One app
last-stack-safe-upgrade-cli situations
last-stack-safe-upgrade-cli fkanban   # also refreshes kanban PATH links
```

**Still artifact / special (not local-safe CLI trees):** last-stack, lastgit,
lastdb/lastdbd Mini (use `lastdb-safe-upgrade` for the primary node).

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

- `artifact-bundle`: install a verified immutable LastGit artifact and expose
  PATH links from its active `current` version.
- `A compile`: legacy checkout-era build and install flow.
- `B checkout-shim`: legacy checkout-era fast-forward and PATH shim flow.
- `C skill-pack`: refresh a skill-pack checkout and rerun its setup.
- `D daemon/cloud`: intentionally out of scope for this driver until a concrete
  app opts in.

The default registry is artifact-backed for `lastgit`, `last-stack`, `brain`,
`situations`, `kanban`, `fkanban`, `lastdb`, and `lastdbd`. The `kanban` and
`fkanban` commands share the `fkanban` artifact bundle. The `lastdb` and
`lastdbd` commands share the `lastdb-bundle` artifact so the invariant can
detect CLI/daemon source or manifest skew; live primary activation still goes
through `lastdb-safe-upgrade`.
