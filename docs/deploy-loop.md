# Production deploys: the deploy-watch routine and the deploy-main graph

Since 2026-09-21 (Tom: "build it directly"). Replaces the per-repo launchd
watchers `com.edgevector.lastgit-deploy-*` (`.lastgit/deploy-run.sh`): one
OID in a file, no heartbeat, disabled for a week before anyone noticed
(`papercut-thelastdb-website-deploy-agent-disabled-in-launchd-20260921`).

## Shape

```
routinesd ─5 min─► last-stack-deploy-watch-gate
                      │  for each enabled repo in config/deploy/repos.json:
                      │  forge tip of main moved? Forge CI success? not deployed, not held?
                      ▼
               last-stack-deploy-loom --repo R --oid O      key deploy-R-O (one execution ever)
                      ▼
               Loom graph deploy-main:  STAGE → DEPLOY (checked effect) → VERIFY → DONE
                      ▼
               deploy-prod status on the commit (forge) · receipt under ~/.local/state/last-stack/deploy/R/O/
```

- **STAGE** clones the exact OID into `<state_root>/<repo>/<oid>/src` (re-entrant).
- **DEPLOY** runs the repo's own script (`.lastgit/deploy-prod.sh` or
  `deploy-pipeline.sh`) from that checkout with the variables the old watcher
  gave it (`LASTGIT_CI_OID`, `LASTGIT_CI_CONTEXT`, `LASTGIT_CI_REPO`) plus the
  repo's `env` from the config. It writes `deploy-receipt.json` (rc, times,
  log path) and emits `LOOM_EFFECT_INTENT {"kind":"deploy"}`. The node is a
  checked effect: `CHECK` answers 0 for a landed receipt, so a resumed
  execution never deploys the same OID twice.
- **VERIFY** runs `verify_command` (with `DEPLOY_OID`, `DEPLOY_REPO`) until it
  passes or 10 min elapse.
- The launcher waits while the execution runs (up to 90 min), then posts
  `<context>` success/failure on the commit and prints `DEPLOY_RESULT`.

## Why not Forge CI

Forgejo cancels an in-progress `push` run when the next merge lands. A
production deploy must not be cut off mid-flight. CI gates the merge; the
routine deploys the merged tip.

## Per-repo behaviour

| Line | Meaning |
|---|---|
| `current@<oid>` | tip equals the last receipt |
| `deployed@<oid>` | deployed this tick |
| `ci_pending@<oid>` | tip moved, CI not finished |
| `ci_failure@<oid>` | tip is red; waits for the next green tip |
| `held_after_failure@<oid>` | this tip's deploy failed; reported once as error, then held until a new commit or `last-stack-deploy-loom --repo R --oid O` by hand after the fix |
| `disabled` | `enabled: false` in the config |

## Config

`config/deploy/repos.json`: `repo`, `enabled`, `context`, `deploy_script`,
optional `env`, `verify_command`, `ref`, `source_url`. Defaults: forge root,
owner, ref, `state_root`. The four repos the launchd agents covered are all
listed; only `fold_db_website` is enabled. The other three
(`exemem-infra`, `schema-infra`, `ops-terminal`) were found disabled in
launchd on 2026-09-21 and stay off until Tom enables them here.

## Venue

The gate reads the forge named in the config. LastGit is retired as a venue
(decision-2026-09-06); there is no switch. If a repo ever moves, the gate
changes, the graph does not.

## Retirement of the launchd agents

`launchctl bootout gui/$UID/com.edgevector.lastgit-deploy-<repo>` and
`launchctl disable …`. The plists stay on disk as history. Their scripts
(`.lastgit/deploy-run.sh`) are no longer executed; the repos' `deploy-prod.sh`
/ `deploy-pipeline.sh` are what the graph runs, unchanged.

## Tests

`tests/last-stack-deploy-loom-steps.sh` (graph steps, hermetic),
`tests/last-stack-deploy-watch-gate.sh` (gate with fake tip/status/deploy),
`tests/last-stack-deploy-watch-routine.sh` (seeder).
