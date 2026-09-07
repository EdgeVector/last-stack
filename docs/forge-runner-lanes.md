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

## Owner PC pause (`heavy` + `pc-linux`)

Both PC lanes run on the gaming PC, so the `.paused-*` LaunchAgent marker that
records a deliberate pause for a Mac lane cannot express one for them. The
factory owns that intent and writes it to a durable file. The watchdog only
reads it.

| | |
|---|---|
| Path | `~/.local/state/last-stack/pc-ci/state.json` |
| Override | `FORGE_WATCHDOG_PC_PAUSE_FILE` (tests and fixtures) |
| Writer | the factory pause/resume control |
| Reader | `bin/last-stack-forge-runner-watchdog` |

```json
{
  "intent": "paused",
  "since": "2026-09-07T09:00:00Z",
  "reason": "owner is gaming"
}
```

- `intent` is the whole contract. `"paused"` means paused. **Every** other
  value — `"normal"`, a missing file, an unreadable file, a half-written file —
  means NOT paused. An unreadable pause file must never silence a merge gate.
- `since` identifies one pause, so the Situations notice is posted once per
  pause and not once per watchdog run. The file's mtime is the fallback.
- `reason` is optional and is quoted back to the owner.

While the pause holds, the watchdog:

1. suppresses the PC lane alerts **only** — `heavy-lane-live`,
   `pc-linux-absent`, `pc-linux-offline`;
2. keeps paging for the Mac runner lanes, local revive failures, the LastGit
   forge supervisor, and every Forgejo API error;
3. reports the drain instead of alerting: `active` means the PC is still
   finishing a job it already accepted, anything else means it has drained;
4. **freezes** the paging state of a suppressed key rather than clearing it. A
   pause is not a recovery. Clearing would page "healthy again" for a lane
   nobody observed and would reset the re-page cooldown, so resume would page
   at once for an outage already reported. Resume restores exactly the state
   the pause froze;
5. records the pause, and later the resume, as one Situations notice each.

Proof: `tests/last-stack-forge-runner-watchdog.sh` (cases 8-18) covers an
active job, the drain, a Mac outage under pause, a forge API failure under
pause, restart persistence, resume with the lane still down, resume with the
lane healthy, and every malformed pause file.

Out of scope for this repo: the factory-side pause control itself — stopping
new jobs on the PC runner services, the guard that keeps the PC
`pc-runner-watchdog` from restarting them, and the HTTP access controls on the
pause endpoint. Those live with the factory. See brain
`papercut-factory-pc-forgejo-runners-lack-owner-pause-20260906`.

## What this does *not* do

- Does not install or re-register runners (ops remains LaunchAgent +
  `forgejo-runner register` when capacity is missing).
- Does not change branch protection or LastGit `--require-status ci-required`.
- Does not move docker merge capacity onto the Mac host (see
  `decision-2026-07-13-forge-ci-drop-mac-docker-label`).

If `--check` fails: inspect `~/.forgejo-runner-host{,-exemem-infra}/config.yml`
labels (`heavy:host`, `macos:host`), capacity, and `launchctl print
gui/$(id -u)/com.edgevector.forgejo-runner-host`.
