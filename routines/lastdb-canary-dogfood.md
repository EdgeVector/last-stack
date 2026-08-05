---
name: lastdb-canary-dogfood
cadence: nightly
description: Dogfood fold main tip from local Forge (probe then safe-upgrade cutover of primary).
---

You are the unattended **LastDB canary dogfood** routine for the **auto release loop**.

Upstream: **`lastdb-canary-build-main`** (~01:17) stages
`~/.local/state/last-stack/canary-builds/<main-oid>/`. If dogfood runs first and
the stage is missing, do **not** invent a GitHub canary — exit
`forge-main-missing` / red and leave build to the next build-main fire (or run
`last-stack-canary-build-main` once if this is a deliberate catch-up).

## Objective

1. Resolve a canary built from **local Forgejo fold `main` tip** (not GitHub).
2. Run **safe-upgrade probe-only** on a CoW copy of the real DB.
3. On GREEN, run **live safe-upgrade `--yes`** so Tom's **sidebin primary** runs that binary.
4. Record ledger state (`dogfood_green` / `dogfood_red`).

**Canonical candidate order** (enforced by `last-stack-lastdb-canary-dogfood`):

1. Explicit `--candidate` / `--version` (operator override only)
2. **`forge-main`** — local `lastdbd` built from fold main tip  
   (`LAST_STACK_CANARY_LOCAL_FALLBACK_BIN`, or  
   `~/.local/state/last-stack/canary-builds/<main-oid>/lastdbd`, or a worktree
   release binary whose git-describe shortsha / manifest `source_git_oid`
   matches main)
3. GitHub prerelease **only if** `LAST_STACK_CANARY_ALLOW_GITHUB=1` **and** the
   release manifest `source_git_oid` equals fold main tip

Do **not** pick “newest canary-named GitHub prerelease” by semver. That path
rolled the primary back to an Aug-1 build on 2026-08-05.

This **does mutate the primary** on cutover. Respect Situation fences. Never kill
`lastdbd` outside safe-upgrade.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq situations lastdb
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
export LAST_STACK_CANARY_AUTO_CUTOVER=1
# Host sets LASTDB_LAUNCHD_LABEL (no personal username in committed prompts).
export LAST_STACK_CANARY_LAUNCHD_CHECK_CMD="${LAST_STACK_CANARY_LAUNCHD_CHECK_CMD:-launchctl print gui/$(id -u)/${LASTDB_LAUNCHD_LABEL}}"
# Fold SoT = local Forgejo (mirror origin). Refresh main before resolve (default).
export LAST_STACK_CANARY_FETCH_MAIN="${LAST_STACK_CANARY_FETCH_MAIN:-1}"
# Do NOT set LAST_STACK_CANARY_ALLOW_GITHUB unless intentionally packaging the
# same main tip via the public CDN.
```

## Before cutover — ensure a main-tip binary exists

If resolve returns `source=forge-main-missing`, **do not** fall back to GitHub.
Build from Forge fold main and stage the binary:

```bash
# example: worktree at origin/main from Forgejo, then
# cargo build --release -p lastdb_node --bin lastdb --bin lastdbd
# stage:
main_oid="$(git -C ~/.cache/edgevector-git/fold.git rev-parse refs/heads/main)"
mkdir -p "$HOME/.local/state/last-stack/canary-builds/$main_oid"
cp target/release/lastdbd "$HOME/.local/state/last-stack/canary-builds/$main_oid/lastdbd"
printf '{"source_git_oid":"%s"}\n' "$main_oid" \
  >"$HOME/.local/state/last-stack/canary-builds/$main_oid/manifest.json"
```

Or set `LAST_STACK_CANARY_LOCAL_FALLBACK_BIN=/path/to/lastdbd` for a trusted path.

## Execute

```bash
"$last_stack/bin/last-stack-lastdb-canary-dogfood" --cutover --json
```

If Situations fence blocks cutover, do **not** force. Exit noop/error with detail.
If `source=forge-main-missing`, exit error and leave a notice — never invent a GH canary.

## Closeout

```text
lastdb-canary-dogfood <ISO-ts> <ok|error> candidate=<id> state=<state> mode=cutover source=<forge-main|…>
```

`ROUTINE_RESULT outcome=<ok|error|noop> detail=candidate=… state=… mode=cutover source=… primary_mutation=<true|false>`
