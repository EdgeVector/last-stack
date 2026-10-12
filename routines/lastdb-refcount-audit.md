---
name: lastdb-refcount-audit
cadence: daily (09:15 local)
description: RETIRED in its copy form (Tom, 2026-10-12). It audited a copy of the primary home. It needs a synthetic-data design before it runs again.
---

You run a periodic LastDB refcount audit. This audit is not a North Star proof.
It never blocks board progress by itself.

## Stop (Tom, 2026-10-12)

Do not run the steps below. They audit a copy of the primary home. Tom directed
that no agent copies the primary database or runs a node on a copy of it
(brain `decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`,
Situation `no-copies-of-primary-database-20261012`). `lastdb-dev up --fresh` now
makes an EMPTY home, so the audit would read no atoms and report `agreement` for
no reason.

Record a noop heartbeat with `detail` set to `retired-needs-synthetic-design`, run
the close-out skill, and print the `ROUTINE_RESULT` trailer. Keep this routine
paused until it has a design that loads synthetic atoms and reachability data.

## Safety

- Never open or change `~/.lastdb` or `~/.folddb`.
- Never copy either one.
- The producer writes candidate and reachability files with the same `copy_id`.
- Do not delete atoms. The grace-window delete job owns deletion.

## Run (retired; kept for the future synthetic design)

Create the isolated EMPTY home, load synthetic data into it, then produce and set all three audit paths:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
# Keep the LastDB socket below the macOS Unix-socket path limit.
work="$(mktemp -d /private/tmp/lastdb-refcount-audit.XXXXXX)"
copy_home="$work/home"
LASTDB_DEV_HOME="$copy_home" lastdb-dev up --fresh --bin "$(command -v lastdbd)"
python3 "$last_stack/harness/north-star/north-star-lastdb-schema-root-data-attribution/produce.py" \
  --copy-home "$copy_home" --out-dir "$work/input" >"$work/paths.json"
LASTDB_REFCOUNT_AUDIT_CANDIDATES="$work/input/candidates.json"
LASTDB_REFCOUNT_AUDIT_REACHABILITY="$work/input/reachability.json"
LASTDB_REFCOUNT_AUDIT_REPORT="$work/report.json"
python3 "$last_stack/harness/north-star/north-star-lastdb-schema-root-data-attribution/audit.py" \
  --candidates "$LASTDB_REFCOUNT_AUDIT_CANDIDATES" \
  --reachability "$LASTDB_REFCOUNT_AUDIT_REACHABILITY" --out "$LASTDB_REFCOUNT_AUDIT_REPORT"
LASTDB_DEV_HOME="$copy_home" lastdb-dev stop
LASTDB_DEV_HOME="$copy_home" lastdb-dev reclaim --home "$copy_home"
```

The producer calls `lastdb db gc-atoms --json` and `lastdb liveness explain`
on the isolated home only. It refuses a home without an owner stamp and socket.

Read `result` from the report.

- `agreement`: record a noop heartbeat.
- `disagreement`: file one Kind:pr bug card for the refcount bookkeeping fault.
  Use `last-stack-kanban-file-pr`. Put each reachable candidate and its root
  groups in the card. Do not label the audit as a terminal proof.
- invalid input or a non-isolated copy: record `error`. Do not substitute a
  primary home or a different copy.

## Close-out

Run the close-out skill before the final result. Write the Brain closeout
report. File a Brain papercut for any new tool friction. Do not create a
papercut board card.

## Result (last)

Print one fresh `ROUTINE_RESULT` trailer as the final output (contract §1).
Set `outcome` to `ok`, `noop`, or `error`. Set `detail` to the
refcount-audit result: `agreement`, `disagreement`, or `invalid`.
