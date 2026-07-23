# Forge runner lanes — merge gate vs heavy release/deploy

Standing rule for the local Forgejo forge (`http://localhost:3300`):

| Lane | Labels | Purpose | Pre-merge required? |
|------|--------|---------|---------------------|
| **merge-gate** | `docker`, `ubuntu-latest`, `ubuntu-22.04`, `macos-arm64`, `pc-linux` | PR `ci-required` only (fmt/clippy / host smoke) | **Yes** — `ci-required` |
| **heavy** | `heavy`, `macos` | Long release/deploy (fold tags, exemem-infra deploys, post-merge heavy clippy) | **No** — never widen merge gates |

This implements the north-star decision on
`north-star-forge-build-release-parity`: release/deploy must **not** share the
capacity-3 (or PC docker) merge-gate runner so PR throughput never starves.

## Local homes (this workstation)

| Home | Expected name | Lane | Capacity | Scope |
|------|---------------|------|----------|-------|
| `~/.forgejo-runner` | `mac-forge-runner` | merge-gate (`macos-arm64`) | 2 | global |
| `~/.forgejo-runner-host` | `mac-forge-runner-host` | **heavy** (`heavy`, `macos`) | 1 | repo `EdgeVector/fold` |
| `~/.forgejo-runner-host-exemem-infra` | `mac-forge-runner-host-exemem-infra` | **heavy** (`heavy`, `macos`) | 1 | repo `EdgeVector/exemem-infra` |
| PC WSL `forgejo-runner` | `pc-forge-runner` | merge-gate (docker/*) | 4 | global |

LaunchAgents (already on host):

- `com.edgevector.forgejo-runner`
- `com.edgevector.forgejo-runner-host`
- `com.edgevector.forgejo-runner-host-exemem-infra`

Policy source of truth in-repo: [`config/forge-runner-lanes.json`](../config/forge-runner-lanes.json).

## Workflow routing

```yaml
# Merge-blocking PR job — merge-gate labels only
jobs:
  fmt:
    runs-on: docker   # or macos-arm64 / pc-linux
  ci-required:
    needs: [fmt, ...]
    runs-on: macos-arm64

# Release / deploy — heavy host lane (NOT in ci-required needs)
jobs:
  release-cli:
    runs-on: heavy    # or macos
    # do NOT add this job as a required status check for merges
```

Rules:

1. **Never** put `runs-on: heavy` (or multi-hour release) into `ci-required`'s
   `needs:` graph.
2. **Never** add a long release/deploy check as a branch-protection / auto-merge
   required context. LastGit / Forge merge still requires only `ci-required`.
3. Prefer repo-scoped heavy runners so fold release capacity and exemem deploys
   do not queue on each other.

## Operator proof command

Local discovery + separation check (uses runner homes + lane config; no forge
write):

```bash
bin/last-stack-forge-runner-lanes --check
```

Expected human output includes:

```text
heavy_ok: true
merge_gate_has_heavy: false
separated_from_merge_gate: true
merge_gate_unchanged: true
check_ok: true
```

JSON:

```bash
bin/last-stack-forge-runner-lanes --check --json
# .heavy_ok == true && .merge_gate_has_heavy == false && .check_ok == true
```

Live (Forgejo up + `forgejo-token` in keychain or `FORGE_TOKEN`):

```bash
bin/last-stack-forge-runner-lanes --check --live
```

Live mode also lists admin (global) merge-gate runners and repo-scoped heavy
runners for `EdgeVector/fold` and `EdgeVector/exemem-infra`.

## What this does *not* do

- Does not install or re-register runners (ops remains LaunchAgent +
  `forgejo-runner register` when capacity is missing).
- Does not change branch protection or LastGit `--require-status ci-required`.
- Does not move docker merge capacity onto the Mac host (see
  `decision-2026-07-13-forge-ci-drop-mac-docker-label`).

If `--check` fails: inspect `~/.forgejo-runner-host{,-exemem-infra}/config.yml`
labels (`heavy:host`, `macos:host`), capacity, and `launchctl print
gui/$(id -u)/com.edgevector.forgejo-runner-host`.
