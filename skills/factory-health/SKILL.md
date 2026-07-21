---
name: factory-health
description: Hourly Kanban Factory health check — ship rate, todo depth, doing age vs baselines; ra notify Tom when out of band. Use when tuning factory-health.toml, debugging false alerts, or reviewing factory health.
---

# Factory health

## Run

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-factory-health" --dry-run --json
"$last_stack/bin/last-stack-factory-health"
"$last_stack/bin/last-stack-factory-health-install" status
```

## Config

Edit `config/factory-health.toml` (or `FACTORY_HEALTH_CONFIG`). Key knobs:

- `ship_rate.soft_ratio` (default 0.5) + `z_score` (1.5) + `consecutive_hours` (2)
- `ship_rate.min_baseline_mean` — don't relative-alert on quiet baselines
- `notify.quiet_hours` — soft muted overnight
- `auto_fix.enabled` — leave false until Tom approves self-heal

## What it measures

- Ships last completed hour vs 24h hourly baseline
- Ships last 24h vs history ring
- Todo depth / empty-queue starvation
- Doing max age + stale count
- Aged doing+pr_url closeout smell

## On alert

Message includes concrete recommendations (usually board-closeout, profile,
pickup). Do **not** auto-apply unless `auto_fix.enabled` and action allowlisted.
