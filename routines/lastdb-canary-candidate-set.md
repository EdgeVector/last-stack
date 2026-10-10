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

The gate runs six steps in this order and stops at the first one that fails.
Step 0 comes first and never stops the gate:

0. **primary-rows** — when registry `next` has no row proved with the build
   the primary runs now, prove the app set against that build (set + smoke on
   the primary's own `lastdbd` + rows). No build, no cutover. When the rows
   exist, it reads each app head (the step 3 pick, `--no-version-lookup`) and
   compares it with the pin in `next`. A moved head runs the same proof. The
   limits: one smoke an hour; a RED set is not smoked again until a head
   moves; a RED files or appends a brain papercut with the smoke output.
   Nothing moved costs one head read and one `lastdb app resolve` per app
   (about 2 s). `--primary-rows-only` runs it
   alone; `--detach` returns at once. The hourly reconcile gate calls it
   that way. A standalone safe upgrade does not start it.
1. **build** — `last-stack-canary-build-main` stages Forge fold `main` under
   `canary-builds/<oid>/` (`already_staged` is fine).
2. **resolve** — the candidate build, the primary build, the cutover-hold
   policy. Same build → `noop`. Hold → `noop`.
3. **set** — `last-stack-canary-candidate-set` fixes one commit per app
   (`config/registry/apps.json`): the artifact channel head, else `main` of
   the app's LastGit repo (its gate of record since era 3).
4. **smoke** — the isolated llms-txt install smoke boots the **candidate**
   `lastdbd` and installs exactly that set (`SMOKE_LASTDBD_BIN`,
   `SMOKE_CANDIDATE_SET`). RED stops here: no cutover, no rows, a
   build-subject line event in the ledger.
5. **cutover** — the bounded safe-upgrade probe + primary cutover.
6. **rows** — `last-stack-registry-publish-next` writes one compat row per
   app to registry `next` and opens an auto-merging GitHub PR on the tap repo (`gh pr merge --auto --squash`, check `ci-required`).

Cargo release builds take 20–40 minutes; the smoke 6–9. Stay on this turn
until the gate exits. Do not background it.

Do not run the old canary release graph. Do not publish brew. Stable stays a
human action (`last-stack-release-publish`).

## Closeout

Print the gate result. Then run the close-out skill. End with the heartbeat and
one `ROUTINE_RESULT` line (the gate already printed one; repeat it).
