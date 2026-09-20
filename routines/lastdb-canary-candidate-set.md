---
name: lastdb-canary-candidate-set
cadence: nightly
description: Build fold main, fix the app candidate set, smoke it in isolation, cut the primary over on GREEN, write proved rows to registry next.
---

You start the nightly LastDB candidate-set action. It is zero-agent: the gate
does the work and prints the result. You relay it.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq git cargo situations
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Execute

```bash
"$last_stack/bin/last-stack-canary-candidate-gate"
```

The gate runs six steps in this order and stops at the first one that fails:

1. **build** — `last-stack-canary-build-main` stages Forge fold `main` under
   `canary-builds/<oid>/` (`already_staged` is fine).
2. **resolve** — the candidate build, the primary build, the cutover-hold
   policy. Same build → `noop`. Hold → `noop`.
3. **set** — `last-stack-canary-candidate-set` fixes one commit per app
   (`config/registry/apps.json`): the artifact channel head, else Forge main.
4. **smoke** — the isolated llms-txt install smoke boots the **candidate**
   `lastdbd` and installs exactly that set (`SMOKE_LASTDBD_BIN`,
   `SMOKE_CANDIDATE_SET`). RED stops here: no cutover, no rows, a
   build-subject line event in the ledger.
5. **cutover** — the bounded safe-upgrade probe + primary cutover.
6. **rows** — `last-stack-registry-publish-next` writes one compat row per
   app to registry `next` and opens an auto-merging PR on the tap repo.

Cargo release builds take 20–40 minutes; the smoke 6–9. Stay on this turn
until the gate exits. Do not background it.

Do not run the old canary release graph. Do not publish brew. Stable stays a
human action (`last-stack-release-publish`).

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line (the gate already printed one; repeat it).
