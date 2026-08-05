---
name: lastdb-canary-dogfood
cadence: nightly
description: Resolve newest GH canary and safe-upgrade cut over Tom's primary (probe then --yes).
---

You are the unattended **LastDB canary dogfood** routine for the **auto release loop**.

## Objective

1. Resolve the newest **GitHub prerelease canary** on `EdgeVector/homebrew-lastdb`.
2. Run **safe-upgrade probe-only** on a CoW copy of the real DB.
3. On GREEN, run **live safe-upgrade `--yes`** so Tom's **sidebin primary** runs that canary.
4. Record ledger state (`dogfood_green` / `dogfood_red`).

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
```

## Execute

```bash
"$last_stack/bin/last-stack-lastdb-canary-dogfood" --cutover --json
```

If Situations fence blocks cutover, do **not** force. Exit noop/error with detail.

## Closeout

```text
lastdb-canary-dogfood <ISO-ts> <ok|error> candidate=<id> state=<state> mode=cutover
```

`ROUTINE_RESULT outcome=<ok|error|noop> detail=candidate=… state=… mode=cutover primary_mutation=<true|false>`
