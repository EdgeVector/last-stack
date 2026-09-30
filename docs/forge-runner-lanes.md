# Forge runner lanes — merge gate vs heavy release/deploy

> **2026-09-30:** only the `lastgit` repo stays on Forgejo; every other EdgeVector
> repo is on GitHub (GitHub Actions). Only the merge-gate lane below is live. The
> heavy lane is retired (`heavy.retired` in `config/forge-runner-lanes.json`): its
> repo-scoped runners served fold and exemem-infra. The watchdog and
> `last-stack-fold-ci-health` no longer check or revive them; Tom may leave
> `com.edgevector.forgejo-runner-host*` loaded or boot them out. The tables below
> describe the retired layout.

Standing rule for the local Forgejo forge (`http://localhost:3300`):

| Lane | Labels | Purpose | Pre-merge required? |
|------|--------|---------|---------------------|
| **merge-gate** | `macos-arm64` | PR `ci-required` only (fmt/clippy / host smoke) | **Yes** — `ci-required` |
| **heavy** | `heavy`, `macos` | Long release/deploy (fold tags, exemem-infra deploys, post-merge heavy clippy) | **No** — never widen merge gates |

This implements the north-star decision on
`north-star-forge-build-release-parity`: release/deploy must **not** share the
capacity-3 merge-gate runner so PR throughput never starves.

## Local homes (this workstation)

| Home | Expected name | Lane | Capacity | Scope |
|------|---------------|------|----------|-------|
| `~/.forgejo-runner` | `mac-forge-runner` | merge-gate (`macos-arm64`) | 2 | global |
| `~/.forgejo-runner-host` | `mac-forge-runner-host` | **heavy** (`heavy`, `macos`) | 1 | repo `EdgeVector/fold` |
| `~/.forgejo-runner-host-exemem-infra` | `mac-forge-runner-host-exemem-infra` | **heavy** (`heavy`, `macos`) | 1 | repo `EdgeVector/exemem-infra` |

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
    runs-on: macos-arm64
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

## Retired: the gaming PC lanes (2026-09-29)

Tom moved every EdgeVector dependency off the gaming PC on 2026-09-29. The PC
runners `pc-forge-runner` (labels `docker`, `pc-linux`) and `pc-heavy-runner`
(label `heavy`) are retired. Every runner is now a Mac host-mode runner.
Also retired: the owner PC pause file (`~/.local/state/last-stack/pc-ci/state.json`),
its watchdog handling, `last-stack-pc-run`, and the `com.edgevector.pc-runner-watchdog`
LaunchAgent. A workflow that still says `runs-on: docker` or `pc-linux` queues
forever; use `macos-arm64`. PC-side stop commands: brain
`reference-gaming-pc-shutdown-runbook-20260929`.

## What this does *not* do

- Does not install or re-register runners (ops remains LaunchAgent +
  `forgejo-runner register` when capacity is missing).
- Does not change branch protection or LastGit `--require-status ci-required`.
- Does not restore a docker lane (see
  `decision-2026-07-13-forge-ci-drop-mac-docker-label`).

If `--check` fails: inspect `~/.forgejo-runner-host{,-exemem-infra}/config.yml`
labels (`heavy:host`, `macos:host`), capacity, and `launchctl print
gui/$(id -u)/com.edgevector.forgejo-runner-host`.
