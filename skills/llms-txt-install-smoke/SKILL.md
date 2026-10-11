---
name: llms-txt-install-smoke
description: |
  Execute the actual first-time app install and startup in an independent owned home.
  Record the matched Mini pair, exact app source receipts, socket, and Schema Service result.
---

# First-time app install and startup

Use the actual installer in an independent owned home. The command name stays the same for existing callers.
Do not add example records, tests, fixtures, or a fixture harness.

## Scope

- Keep the primary LastDB and its service unchanged.
- Use the selected CLI and daemon from the same Mini build.
- Install the exact app sources in the candidate set.
- Require each source receipt to match the actual app checkout.
- Require each installed command to resolve inside the owned home.
- Refuse an unproved source fallback.
- Do not remove another run's files from their age alone.

## Command

```bash
bash skills/llms-txt-install-smoke/run.sh --json --keep
```

Set `SMOKE_LASTDBD_BIN` to the candidate daemon path. Its sibling CLI is the default `SMOKE_LASTDB_BIN`.
Set `SMOKE_CANDIDATE_SET` to the exact candidate set.
In CI, set `SMOKE_LAST_STACK_OID` to the workflow source OID.

The command uses the real installer, app source checkouts, dependency build, and command links.
It starts one owned daemon and checks its socket, health, and served build.
It uses the actual first-time app setup and Schema Service calls.
App setup is an install step. Do not use setup or doctor for a primary health check.

## Receipt

The JSON receipt names `proof_kind: app_install_startup`.
A GREEN receipt requires success from the actual install and startup steps.
An incomplete command or absent verdict is a failed check.

This receipt covers app install and startup. It does not cover cloud purge, Org roles, or exact cloud recovery.
Keep separate actual product receipts for those actions. Bind each receipt to the exact Mini and app sources.

## Bounds and cleanup

Keep the command in the foreground. The global deadline bounds each step.
The command stops its owned daemon before cleanup.
Use `--keep` until the required proof and recovery files move to their retained destination.
For later cleanup, check the exact path, realpath, owner, and node state.
Keep a retained path if its cleanup fails.

## Failure

Keep the command log and exact failed step. Search the Brain for a remedy.
File a distinct papercut in the Brain. Do not file a papercut card.
Use the board for a separate repair unit when the repair needs a PR.
For a scheduled routine, complete the required Brain closeout before the routine result.
