---
name: lastdb-canary-build-main
cadence: nightly
description: Build Forge fold main tip and stage canary-builds for dogfood (no primary cutover).
---

You are the unattended **LastDB canary build** routine — step 0 of the auto
release loop.

## Objective

1. Resolve **local Forgejo fold `main` tip** (mirror under
   `~/.cache/edgevector-git/fold.git`, origin = Forge).
2. If `~/.local/state/last-stack/canary-builds/<oid>/` already has matching
   `lastdbd` + `manifest.json`, exit ok (`already_staged`).
3. Else **cargo build --release** Mini (`lastdb` + `lastdbd`) at that OID in an
   isolated worktree and stage binaries + manifest for dogfood/promote.
4. **Do not** cut over the primary. **Do not** publish brew.

Downstream:

- `lastdb-canary-dogfood` (~03:17) consumes the stage and may cut over primary
- `lastdb-canary-soak-watch` (hourly) → 24h soak
- `lastdb-canary-promote-prepare` → brew stable from the same OID

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git cargo jq
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_FETCH_MAIN=1
# Optional: pin workdir / builds root
# export LAST_STACK_CANARY_BUILD_WORKDIR=$HOME/.local/state/last-stack/canary-build/fold-worktree
# export LAST_STACK_CANARY_BUILDS_DIR=$HOME/.local/state/last-stack/canary-builds
```

## Execute

```bash
"$last_stack/bin/last-stack-canary-build-main" --json
```

Expect:

- `status=already_staged` — main tip already packaged (ok)
- `status=built` — fresh stage written under canary-builds/`source_git_oid`
- nonzero exit — build failed; **do not** fall back to GitHub; leave a clear
  error for the next dogfood to red as `forge-main-missing` if no prior stage

Cargo release builds can take 20–40+ minutes. Stay on this turn until the
command exits; do not background and walk away.

## Closeout

```text
lastdb-canary-build-main <ISO-ts> <ok|error> status=<status> oid=<short> rebuilt=<true|false>
```

`ROUTINE_RESULT outcome=<ok|error|noop> detail=status=… oid=… rebuilt=… primary_mutation=false`
