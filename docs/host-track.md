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
host-track validate-registry --json
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
`versions/<manifest-digest>` directory, **probes that tree while `current`
still points at last-known-good**. If the app sets `safe_upgrade.soak_hours`
and a live current exists, refresh parks a `canary` pointer and leaves PATH
alone; `host-track soak-watch` re-probes and promotes after the window.
`--activate` (or `soak_hours: 0`, last-stack) flips `current` on GREEN probe.
The displaced version remains at `previous` for `host-track rollback`.
`host-track check` verifies the active payload hashes as well as freshness.
It refuses to replace a non-symlink command target.
When configured, `post_install` runs on the version tree **before the probe**
(so bun/npm hooks exist for the smoke) unless the app sets
`safe_upgrade.post_install_phase` to `after-cutover` (last-stack `setup`,
which rewrites live links). A failed hook or a RED probe leaves the app
stale (no new stamp) and does not flip PATH.

Every artifact app must declare `safe_upgrade.probes` — argv relative to the
version tree. `host-track validate-registry` fails closed when an artifact
app has none. Brain / kanban / situations also set `"latency": true` so a
correct-but-much-slower candidate is RED against the current tree. Tom-only
escape: `HOST_TRACK_PROBE_SKIP=1`. LastDB Mini stays on `lastdb-safe-upgrade`.

### Last Stack one rule (artifact is the only runtime)

**Runtime install = Host Track CI artifact that tracks green main. Never a place you develop.**

Mental model: the live stack **is** main, with a short CI/publish lag. It is
still an immutable content-addressed artifact (not a git working tree), but
`host-track refresh last-stack` promotes `stable` to the newest **green +
published** main oid and installs it. Status `gate_head` is the real main tip;
`stale=true` means the installed oid is not that tip yet (CI pending, publish
missing, or refresh not run). Do **not** treat a manually-frozen stable
pointer as the long-term source of truth.

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
- `behind_by` (commit distance when the installed and gate OIDs are available)
- `binary_pair_match`, `paired_version`, `paired_head`, and
  `deployment_problem` for safe-upgrade-managed binary pairs
- `stamp`
- `refresh`
- `notes`

Use `host-track status --stale` (optionally with `--json`) to show only apps
whose measured `stale` value is true. Unknown measurements are not silently
included as fresh.

Artifact-backed records also report `artifact_app`, `artifact_channel`,
`artifact_root`, `install_root`, `manifest_digest`, and
`channel_manifest_digest`.


## Registry compliance (artifact | exempt | non_compliant)

North Star end-state #6: every registered agent-facing app is either on verified
`install_mode: artifact` or declares an explicit machine-readable
`artifact_exemption`. Status and `validate-registry` surface this without a
separate forever routine.

| `registry_compliance` | Meaning |
|-----------------------|---------|
| `artifact` | `install_mode=artifact` |
| `exempt` | non-artifact with valid `artifact_exemption` (`kind` + `owner` + `rationale`) |
| `non_compliant` | neither — including any remaining non-exempt non-artifact entries |

Allowed exemption `kind` codes (short, machine-readable):

- `bootstrap-recovery` — substrate that must stay checkout-backed so the forge
  can still be repaired when artifact/CR paths are unhealthy (seed: `lastgit`).
- `deployment-only` — install/activation is intentionally outside generic Host
  Track refresh (seed: `lastdb` / `lastdbd` via `lastdb-safe-upgrade`). These
  apps may still declare report-only `deployment_binary`,
  `deployment_peer_binary`, and `deployment_repo_cache` fields. Status reads
  their embedded Git version stamps and the protected gate ref; refresh remains
  explicitly disabled even when status reports `stale=true`.

### Adding a new exemption (no forever routine)

1. Edit `config/host-track/apps.json` for the app. Keep or set a non-artifact
   `install_mode` only when artifact mode is genuinely wrong.
2. Add:

```json
"artifact_exemption": {
  "kind": "deployment-only",
  "owner": "platform",
  "rationale": "One sentence why Host Track artifact refresh must not own this app."
}
```

3. Run the fail-closed policy scan (pure registry; no live installs):

```bash
host-track validate-registry --json
# or against a fixture:
HOST_TRACK_REGISTRY=/path/to/apps.json host-track validate-registry
```

4. Land via the normal last-stack CR path. Continuous health remains the
   **fleet channel freshness gate** (below) — wire it as a dogfood-registry
   maintain recipe, not a new forever routine. `validate-registry` keeps fleet
   migration pressure visible as `non_compliant`; the live invariant still
   accepts healthy `local-safe` installs when present.

Do **not** invent a new scheduled routine for exemption drift. Wire checks into
`host-track status` / `validate-registry` / the fleet gate dogfood entry.

## Fleet channel freshness gate (NS end-state #7)

`bin/last-stack-fleet-channel-freshness-gate` is the **single** machine-checkable
fleet-rollout acceptance gate for `north-star-artifact-driven-host-track`. It
composes prior PRs without a hollow Kind:validation shell:

1. `host-track validate-registry` — every registered app is **artifact or exempt**, and every artifact app declares `safe_upgrade.probes`
2. `last-stack-host-track-artifact-invariant` — every artifact channel is
   **fresh** (`stale=false`), provenance/hashes hold, and **rollback targets**
   resolve when `previous` exists

```bash
# Full live gate (dogfood-registry maintain recipe / non-sandboxed runner)
bin/last-stack-fleet-channel-freshness-gate
bin/last-stack-fleet-channel-freshness-gate --json

# Pure registry policy only (CI / fixtures; no live installs)
bin/last-stack-fleet-channel-freshness-gate --registry-only
HOST_TRACK_REGISTRY=/path/to/apps.json bin/last-stack-fleet-channel-freshness-gate --registry-only
```

**PASS evidence** (first line starts with `PASS`):

`~/.last-stack/feature-proofs/artifact-driven-host-track-fleet-gate.md`

Override with `--proof <path>` or `LAST_STACK_FLEET_CHANNEL_FRESHNESS_PROOF`.
Failure lines name **app + invariant code** (e.g. `situations: stale — …`).

**dogfood-registry maintain recipe (recommended):**

```text
recipe: last-stack-fleet-channel-freshness-gate
pass = exit 0 and proof file begins with PASS
isolation: host-local Host Track installs; never mutates primary brain
```

## Continuous Artifact Invariant

`bin/last-stack-host-track-artifact-invariant` is the live half of the fleet gate
(and remains callable alone). It inventories every registered app, rejects
non-artifact installs without a machine-readable exemption, checks the selected
channel and `stale:false`, verifies exact manifest source provenance, rehashes
active payload files, confirms command paths resolve inside immutable
`versions/<manifest>` directories, compares paired `lastdb` and `lastdbd` bundle
identity when both are registered, and proves rollback state by inspecting the
`previous` symlink without switching it.

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
Prefer the **fleet channel freshness gate** for the composed fleet acceptance
check (registry policy + freshness + rollback). Run after refreshing promoted
artifacts when you need per-app `host-track check` as well:

```bash
host-track refresh --all
bin/last-stack-fleet-channel-freshness-gate
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
- **Mapped apps:** last-stack / brain / situations / fkanban|kanban (app `kanban`) →
  `host-track refresh` (artifact + `track_gate_main`); routines, lastsecrets,
  configurations, search → `host-track refresh` (artifact + track_gate_main)
- **Failure:** log + retry (max 3); **does not unmerge**; operator can run
  `host-track refresh <app>` (artifact) or `last-stack-safe-upgrade-cli <app>`
  (local-safe) manually
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

`host-track refresh <app>` for agent CLIs with `install_mode=artifact` promotes stable via track_gate_main and installs the published build.
For **artifact** apps it promotes (when `track_gate_main`) and installs the
channel tip. LaunchAgent `com.edgevector.host-track-refresh` runs
`host-track refresh --all`, which also ticks `soak-watch --all` so a parked
canary promotes after its window without a second job.

**Artifact CLIs (producers live):** last-stack, remote, brain, situations,
kanban (shared `fkanban` install_root; public CLI is `kanban` only). See
`templates/host-track/README-artifact-producer.md`.

**Still local-safe (await producers):** routines, lastsecrets, configurations,
search.

```bash
# Upgrade artifact CLIs (examples)
host-track refresh routines
host-track refresh lastsecrets
# Legacy local-safe helper (only if an app is still local-safe):
last-stack-safe-upgrade-all-local

# One remaining local-safe app
last-stack-safe-upgrade-cli routines
last-stack-safe-upgrade-cli lastsecrets
```

**Special exemptions (not Host Track artifact refresh):** lastgit
(`bootstrap-recovery`), lastdb/lastdbd Mini (`deployment-only` — use
`lastdb-safe-upgrade` for the primary node).

## Refresh Agent

`./setup` installs a user LaunchAgent named
`com.edgevector.host-track-refresh`. The plist lives at
`~/.last-stack/launchd/com.edgevector.host-track-refresh.plist` and runs:

```bash
~/.local/bin/host-track refresh --all   # also runs soak-watch --all
```

The safety poll runs every 20 minutes. After a GREEN probe it parks `canary`
when `soak_hours > 0`. The same job re-probes those canaries; after the
window it flips `current`. When the registry has Forgejo-gated apps
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
`situations`, `kanban`, `lastdb`, and `lastdbd`. The public board CLI is
`kanban`; it installs from the `fkanban` artifact bundle. The `lastdb` and
`lastdbd` commands share the `lastdb-bundle` artifact so the invariant can
detect CLI/daemon source or manifest skew; live primary activation still goes
through `lastdb-safe-upgrade`.
