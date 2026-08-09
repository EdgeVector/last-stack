---
name: lastdb-canary-promote-prepare
cadence: hourly
description: Auto-promote soak_green canary to public brew stable (local-canonical / Forge SoT).
---

You are the unattended **LastDB canary auto-promote** routine.

## Objective

When ledger is `soak_green` (24h soak complete, primary still on canary):

1. Stage that canary's package from **local Forge builds**  
   (`~/.local/state/last-stack/canary-builds/<source_git_oid>/`).
2. Compute next stable `vX.Y.Z`.
3. Run `forge-promote-homebrew-stable.sh --publish` (local-canonical brew path;
   GitHub is **bottle CDN only**).
4. Mark ledger `promoted` and notify Tom.

Do **not** download a random GitHub prerelease by tag name. GitHub asset fetch
requires `LAST_STACK_CANARY_ALLOW_GITHUB=1` and is only for the same OID when
local packaging is absent.

**This mutates the public brew release.** It does **not** cut over the primary
(primary already runs the canary).

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq gh lastdb
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_PROMOTE_AUTO=1
# GH_TOKEN from gh auth if unset — used only to publish public bottles/tap mirror
export GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
```

## Execute

Inspect the ledger only with the canonical JSON form below. `--json` is a
global flag and must appear before the subcommand; there are no `status` or
`ledger` subcommands. Do not probe by guessing command shapes.

```bash
"$last_stack/bin/last-stack-canary-pipeline" --json list
```

Do not call `promote-prepare` just to inspect state. The routine's action is:

```bash
"$last_stack/bin/last-stack-canary-pipeline" promote-execute
```

If not `soak_green`, expect blocked/noop. Do not force-tag.
If assets missing: stage the soaked main-tip package under canary-builds, then retry.

## Closeout

`ROUTINE_RESULT outcome=<ok|error|noop> detail=status=<status> stable_mutation=<true|false>`
