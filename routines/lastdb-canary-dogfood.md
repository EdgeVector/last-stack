---
name: lastdb-canary-dogfood
cadence: nightly
description: Start (or resume) the lastdb-canary-release state machine — build fold main, probe, cut over the primary.
---

You are the unattended **LastDB canary dogfood** routine — the nightly entry
point of the **auto release loop**.

You do not drive the phases yourself. The loop is a durable **state machine**
(`sm`, the `state-machine` app on LastDB): `lastdb-canary-release`, with states
`BUILD → PROBE → CUTOVER → VERIFY → LEDGER → SOAK ⇄ SOAK_WAIT → PROMOTE`. Your
job is to **start one execution per fold main tip and tick it**. The machine
owns the candidate, the fences, the soak clock, and the ledger.

Why a machine and not four cron steps: the previous shape re-derived the
candidate at each stage from "current main tip", so a merge landing between
BUILD and CUTOVER discarded a good build; and each stage's failure was a
separate cron with its own idea of state. The machine pins
`context.candidate` at BUILD and every later step consumes that exact binary.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git jq situations lastdb sm
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
# Host sets LASTDB_LAUNCHD_LABEL (no personal username in committed prompts).
export LAST_STACK_CANARY_LAUNCHD_CHECK_CMD="${LAST_STACK_CANARY_LAUNCHD_CHECK_CMD:-launchctl print gui/$(id -u)/${LASTDB_LAUNCHD_LABEL}}"
export LAST_STACK_CANARY_FETCH_MAIN="${LAST_STACK_CANARY_FETCH_MAIN:-1}"
# Do NOT set LAST_STACK_CANARY_ALLOW_GITHUB unless deliberately packaging the
# same main tip via the public CDN. GitHub prereleases are never the source of
# truth: picking the newest canary-named prerelease by semver is what rolled the
# primary back to an Aug-1 build on 2026-08-05.
# Do NOT set LAST_STACK_CANARY_PROMOTE_AUTO. v1 prepares and notifies; Tom
# confirms the public brew publish (Tom, 2026-08-06).
```

## Execute

One execution per main tip. The idempotency key makes a second fire on the same
tip a no-op rather than a duplicate cutover:

```bash
main_oid="$(git -C ~/.cache/edgevector-git/fold.git rev-parse refs/heads/main)"
sm start lastdb-canary-release \
  --input "{\"main_oid\":\"$main_oid\"}" \
  --idempotency-key "canary-$main_oid" \
  --concurrency-key lastdb-canary-release
sm tick --definition lastdb-canary-release --cap 6
sm list --definition lastdb-canary-release --json
```

`--concurrency-key` is what keeps two nights from cutting over at once if a
soak is still running. Never pass `--force`; a refused start means the previous
execution has not finished, which is the interlock working.

## Reading the result

- `status=running` / `waiting` — the machine is mid-flight. Normal. `SOAK_WAIT`
  is a 1h timer; the hourly `lastdb-canary-soak-watch` routine ticks it.
- `state=BUILD` with a failure — no candidate could be built from main tip.
  That is **not** a verdict on any binary; do not report it as a bad build.
- `situation_fence needs_human` / `blocked` — a scoped
  `situations preflight --action lastdb-safe-upgrade` said no. The execution
  PARKS and retries; do not force it, and cite the Situation slug.
- `status=failed` at PROBE/CUTOVER/VERIFY — a real candidate really failed.
  This is the only shape that means "the build is bad."

This routine **does mutate the primary** at CUTOVER, through safe-upgrade only.
Never kill `lastdbd` yourself.

## Closeout

```text
lastdb-canary-dogfood <ISO-ts> <ok|error|noop> exec=<id> state=<state> status=<status> main=<oid12>
```

`ROUTINE_RESULT outcome=<ok|error|noop> detail=exec=… state=… status=… main=… primary_mutation=<true|false>`

Use `noop` when the machine is mid-flight or the start was deduped — a loop that
is working is not an error.
