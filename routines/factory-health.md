---
name: factory-health
cadence: hourly (:17)
description: Kanban Factory health — ship rate, todo depth, doing age vs rolling baselines; message Tom on out-of-band; auto-fix opt-in later.
---

You are the **factory-health** routine. Prefer the **LaunchAgent** + deterministic
binary (zero LLM). If scheduled on an LLM harness, only run the binary and echo
its heartbeat.

## Why

The factory can look "fine" while:

- ship rate drops vs the last 24h average
- cards sit in `doing` for hours (merged-but-not-closed, zombies)
- `todo` piles up or starves

LLM watch/pickup can be paused (low-credit). This check is **always-on** and
pages Tom via `ra notify` before any auto-fix.

## Config

```bash
$EDITOR "${LAST_STACK_ROOT:-$HOME/.last-stack}/config/factory-health.toml"
```

Bands use **dual gates + hysteresis** to limit false positives:

| Gate | Purpose |
|------|---------|
| `soft_ratio` / `hard_ratio` vs 24h mean | e.g. last hour < 50% of mean |
| `z_score` | last hour also < mean − z·σ |
| `consecutive_hours` (default 2) | must fail 2 completed hours in a row |
| `min_baseline_mean` | skip relative alerts when baseline is quiet |
| `quiet_hours` | soft alerts muted overnight; hard can still fire |

Uses **completed** hour buckets (not the partial current hour).

## Run

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-factory-health-install" install
"$last_stack/bin/last-stack-factory-health" --dry-run --json
"$last_stack/bin/last-stack-factory-health"
```

LLM harness path:

```bash
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-factory-health"
# Final response = the printed factory-health … line only
```

## Phases

1. **Notify only** (`auto_fix.enabled = false`) — message with diagnosis +
   recommended fixes for Tom / remote agent to approve.
2. **Opt-in auto_fix** — enable actions like `board_closeout` in config after
   trust is earned.

## Related

- `preference-kanban-board-closeout-always-on`
- `last-stack-board-closeout-sweep`
- Factory UI: http://127.0.0.1:4177
- Skill: `factory-health`
