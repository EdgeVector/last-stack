---
name: lastdb-refcount-audit
cadence: daily (09:15 local)
description: RETIRED (Tom, 2026-10-12). It audited a copy of the primary home. The record model removed the counts it audited.
---

You run a retired LastDB refcount audit. This audit is not a North Star proof.
It never blocks board progress by itself.

## Stop (Tom, 2026-10-12)

Do not audit anything. The old steps audited a copy of the primary home. Tom
directed that no agent copies the primary database or runs a node on a copy of
it (brain `decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`,
Situation `no-copies-of-primary-database-20261012`). LastDB now stores one
record per key, and the node has no command that lists the old reference
counts, so the audit has no input.

Record a noop heartbeat with `detail` set to `retired-needs-synthetic-design`, run
the close-out skill, and print the `ROUTINE_RESULT` trailer. Keep this routine
paused until it has a new design that uses synthetic data.

## Safety

- Never open or change `~/.lastdb`.
- Never copy it.
- Do not delete records.

## Close-out

Run the close-out skill before the final result. Write the Brain closeout
report. File a Brain papercut for any new tool friction. Do not create a
papercut board card.

## Result (last)

Print one fresh `ROUTINE_RESULT` trailer as the final output (contract §1).
Set `outcome` to `noop` and `detail` to `retired-needs-synthetic-design`.
