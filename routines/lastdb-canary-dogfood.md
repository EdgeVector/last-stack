---
name: lastdb-canary-dogfood
cadence: nightly
description: Start one bounded main-build probe and primary cutover action for canary v2.
---

You start the primary-channel action for LastDB canary v2.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq situations
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Execute

Run the zero-agent gate.

```bash
"$last_stack/bin/last-stack-canary-v2-dogfood-gate"
```

The gate resolves one build from Forge fold main. It applies the cutover-hold
policy before it starts the action. It starts the bounded safe-upgrade action
for probe and cutover. It does not start the retired release graph.

After the daemon starts, its durable Fold boot row becomes the candidate
evidence. The hourly v2 reconciler measures the quiet window. It chooses the
stable-channel action only after a green verdict.

Do not run the old canary release graph. Do not start a wait state. Do not
publish brew from this routine.

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line.
