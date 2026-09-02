---
name: lastdb-canary-promote-prepare
cadence: hourly
description: Held stable-channel action during the canary v2 migration.
---

This routine is paused during the canary v2 migration.

Do not run `promote-execute`. Do not publish brew. The old promotion path uses
the retired state-machine soak result and cannot certify a v2 build.

The v2 reconciler records `promote-eligible` only after a completed quiet
window. Stable publication stays held until the channel proof and the explicit
short action command are available.

If this paused prompt runs, emit
`ROUTINE_RESULT outcome=<noop> detail=status=paused stable_mutation=false`.
