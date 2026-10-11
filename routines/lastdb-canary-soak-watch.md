---
name: lastdb-canary-soak-watch
cadence: hourly
description: Reconcile LastDB canary v2 from durable boot and observation evidence.
---

You run the stateless LastDB canary v2 reconciler once each hour.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq curl situations
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Execute

Run the zero-agent gate first.

```bash
"$last_stack/bin/last-stack-canary-reconcile-gate"
```

Before the verdict, the wrapper starts the candidate gate's primary-rows step
detached (`--primary-rows-only --detach`, one line on stderr). It proves
registry `next` rows for the build the primary runs when none exist, or when
an app head moved past its pin (at most one smoke an hour). It is skipped on a
dry run.

The gate reads the owner-only bounded boot ledger. It records a three-sample
status p95 with a 2-second budget. It records the host fence separately.

The gate then runs the deterministic verdict function against immutable rows.
It appends one reconciler row. It has no active marker, resume key, or wait
state. It does not run a Loom graph.

The result has one of these forms:

- `green`: The quiet window is complete. The candidate is eligible for the
  held promotion action.
- `red`: The build failed. A short configured heal action can run.
- `line-stopped`: The observer failed. A short configured line-stop action can
  run.
- `window-open`: The time window stays open. A host failure pauses the window.
- `superseded`: A newer build replaced the candidate.

Timeout, absence, and status p95 above 2 seconds are failures. A missing boot
row is build failure evidence.

## Action safety

The gate executes exactly one configured short action per verdict token. By
default only `promote-eligible` has a command: `last-stack-canary-promote-material`
writes `PROMOTE.md` (the node build and the registry `next` rows proved with
it), then runs `last-stack-release-publish --lastdb-version <build>
--if-needed` and notifies with the result. Since 2026-09-21 a green quiet
window IS the stable decision (decision-2026-09-21-stable-publish-is-automatic-on-green).
The publisher refuses a build with no proved `next` rows and skips halves
that are already public. A failed promote action is retried on a
later hourly tick: at most `LAST_STACK_CANARY_V2_PROMOTE_MAX_ATTEMPTS`
attempts (default 6), at least `LAST_STACK_CANARY_V2_PROMOTE_RETRY_SECONDS`
apart (default 3000). Each retry posts a Situations notice, and so does the
last failed attempt. Other actions stay one attempt per verdict token.
The publisher takes the LastDB promote script from accepted GitHub main (the
bare mirror `~/.cache/edgevector-git/lastdb.git`, fetched first), never from
`~/.lastgit/mirrors`, and refuses a script that names a `lastdb:///` remote. The other actions stay planned until a command is
configured.

Allowed actions: build, heal, line-stop, pause, retire, promote.
`wait-next-check` is a fact for the next tick. The dispatcher never starts it.

Per-action commands:

```bash
LAST_STACK_CANARY_V2_BUILD_CMD='short-command'
LAST_STACK_CANARY_V2_HEAL_CMD='short-command'
LAST_STACK_CANARY_V2_LINE_STOP_CMD='short-command'
LAST_STACK_CANARY_V2_PAUSE_CMD='short-command'
LAST_STACK_CANARY_V2_RETIRE_CMD='short-command'
LAST_STACK_CANARY_V2_PROMOTE_CMD='short-command'
```

`LAST_STACK_CANARY_V2_ACTION_CMD` is a fallback action command. A missing
command leaves the action planned. It does not invent a wait loop.

`--dry-run` (or `LAST_STACK_CANARY_V2_DRY_RUN=1`) prints the action plan and
writes no reconciler evidence, primary state, or stable-channel state.

Stable publication is automatic on green. The same command works by hand
(`last-stack-release-publish --lastdb-version <build> [--dry-run]`) and
`LAST_STACK_RELEASE_AUTO_PUBLISH=0` returns the action to material-only.

Stable publication requires the existing key locator in
`LASTDB_REGISTRY_SIGNING_KEY_LASTSECRETS=lastsecrets://<existing-key-slug>`.
The publisher passes LastSecrets stdout directly to the native signer on stdin.
It checks the fixed existing public release trust key. It does not use a local key file.

Set `LAST_STACK_REGISTRY_TAP_DIR` and `LAST_STACK_FORMULA_TAP_DIR` to two
independent clean registered DEV worktrees. Both start at current accepted
GitHub tap main. The publisher never resets or replaces either checkout.
It validates the real hosted install/startup proof and public source reachability
before either public step. A refusal keeps the same quiet gate and retry policy.
A newer accepted helper source is recorded separately from the proved Mini source.

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line.
