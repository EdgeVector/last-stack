---
name: lastdb-canary-red-heal
cadence: hourly
description: Retired recovery lane during the canary v2 migration.
---

This routine is paused.

Canary v2 does not use a recovery graph. The hourly stateless reconciler
re-checks durable evidence. It writes a heal-queue row for a build failure. It
dispatches a configured short action once per failure class.

Do not start the retired red-heal Loom graph. Do not retry a candidate because a
timer fired. A new action needs new durable evidence or an explicit operator
decision.

If this paused prompt runs, emit
`ROUTINE_RESULT outcome=<noop> detail=status=paused action=none`.
