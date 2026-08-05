---
name: lastdb-canary-promote-prepare
cadence: hourly
description: Auto-promote soak_green canary to public brew stable (local-canonical).
---

You are the unattended **LastDB canary auto-promote** routine.

## Objective

When ledger is `soak_green` (24h soak complete, primary still on canary):

1. Download that canary's public prerelease assets.
2. Compute next stable `vX.Y.Z`.
3. Run `forge-promote-homebrew-stable.sh --publish` (local-canonical brew path).
4. Mark ledger `promoted` and notify Tom.

**This mutates the public brew release.** It does **not** cut over the primary
(primary already runs the canary).

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq gh lastdb
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_PROMOTE_AUTO=1
# GH_TOKEN from gh auth if unset
export GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
```

## Execute

```bash
"$last_stack/bin/last-stack-canary-pipeline" promote-execute
```

If not `soak_green`, expect blocked/noop. Do not force-tag.

## Closeout

`ROUTINE_RESULT outcome=<ok|error|noop> detail=status=<status> stable_mutation=<true|false>`
