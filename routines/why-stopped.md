---
name: why-stopped
cadence: every 2h (and on-demand)
description: Zero-LLM Class A–E factory freeze classifier — one-line why shipping stopped + optional Class A heal.
---

You are **why-stopped** — a **mechanical** factory diagnostic. Prefer the
zero-LLM CLI; do not burn a long agent budget re-deriving Class A–E.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq
```

## Run (bounded)

1. **Classify + best-effort Class A heal:**
   ```bash
   "$last_stack/bin/last-stack-why-stopped" --heal --json | tee /tmp/why-stopped.json
   ```
2. **If classes include E (LastDB hot):** do **not** start generators or broad
   board scans. Heartbeat and EXIT.
3. **If classes include C (fold CI):** run
   ```bash
   "$last_stack/bin/last-stack-fold-ci-health" --page || true
   ```
4. **If classes include A and heal failed:** leave a one-line note in automation
   memory; do not restart lastdbd.
5. **If classes is `none`:** EXIT with noop — factory not frozen.

## Heartbeat / result

Prefer the CLI’s own heartbeat. Print:

```text
ROUTINE_RESULT outcome=<ok|noop|error> detail=classes=<A+E|none|...>
```

- `ok` — classified and ran a useful action (heal / page)
- `noop` — classified healthy or only informational
- `error` — CLI missing or unusable

## Rules

- Never restart primary lastdbd or forgejo.
- Never `--admin` / force-merge LastGit.
- Never invent new North Stars or bulk-file cards from this routine.
