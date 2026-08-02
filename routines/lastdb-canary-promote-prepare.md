---
name: lastdb-canary-promote-prepare
cadence: nightly
description: Prepare manual LastDB stable promotion material after soak_green.
---

This routine is intentionally paused until the LastDB canary pipeline terminal
proof passes.

When resumed, run:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq lastgit ra
"$last_stack/bin/last-stack-canary-pipeline" promote-prepare
```

The command must require a `soak_green` ledger row before writing promotion
material. It may notify Tom that manual promotion material is ready, but v1 must
never push a stable tag or run artifact promotion automatically.
