---
name: lastdb-canary-dogfood
cadence: nightly
description: Resolve a LastDB canary candidate and dogfood the safe-upgrade probe path. Paused until terminal proof passes. Never mutates the primary install.
---

You are the unattended **LastDB canary dogfood** routine.

## Objective

Resolve the newest LastDB canary candidate, run the safe-upgrade preflight path
only, and record the candidate lifecycle in the canary ledger. This routine
must not change Tom's primary LastDB install. Promotion is a later routine after
dogfood and soak evidence are green.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq situations
```

Use Situations before any live probe. If a Situation blocks primary upgrade,
kickstart, or cutover, this routine may still run dry-run mode. Do not restart
or kill `lastdbd`.

## Modes

- Default / dry run:
  ```bash
  "$last_stack/bin/last-stack-lastdb-canary-dogfood" --dry-run --json
  ```
  This resolves GitHub prerelease canary metadata, falls back to a local main
  candidate when release metadata is unavailable, records
  `candidate_found -> dogfood_started -> dogfood_green`, and exits without
  running safe-upgrade or changing the primary install.

- Live dogfood:
  ```bash
  "$last_stack/bin/last-stack-lastdb-canary-dogfood" --live --json
  ```
  This runs `safe-upgrade-lastdb.sh --probe-only` for the resolved candidate.
  Probe-only may create a durable backup and CoW probe copy, but it must not
  activate, kickstart, or replace the primary binary. Record
  `dogfood_green` only when the real-data probe is green; otherwise record
  `dogfood_red`.

## Candidate Resolution

Prefer GitHub prerelease canary metadata from
`EdgeVector/homebrew-lastdb` releases. If that cannot be read or has no
prerelease candidate, use the local main fallback only when a release `lastdbd`
binary is available; otherwise dry-run records a local-main-unbuilt candidate
so the ledger shows that no primary mutation was attempted.

## Closeout

Append a heartbeat last:

```text
lastdb-canary-dogfood <ISO-ts> <ok|error> candidate=<id> state=<state> mode=<dry-run|live>
```

Print the machine-result token followed by
`outcome=<ok|error> detail=candidate=<id> state=<state> mode=<mode>`.
