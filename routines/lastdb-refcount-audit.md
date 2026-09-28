---
name: lastdb-refcount-audit
cadence: daily (09:15 local)
description: Audit refcount-zero grace-window candidates against schema, retention, and system reachability on one isolated copy.
---

You run a periodic LastDB refcount audit. This audit is not a North Star proof.
It never blocks board progress by itself.

## Safety

- Use one isolated CoW copy. Never open or change `~/.lastdb` or `~/.folddb`.
- Use candidate and reachability files that name the same `copy_id`.
- Do not delete atoms. The grace-window delete job owns deletion.

## Run

The isolated-copy job supplies these paths:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
python3 "$last_stack/harness/north-star/north-star-lastdb-schema-root-data-attribution/audit.py" \
  --candidates "$LASTDB_REFCOUNT_AUDIT_CANDIDATES" \
  --reachability "$LASTDB_REFCOUNT_AUDIT_REACHABILITY" \
  --out "$LASTDB_REFCOUNT_AUDIT_REPORT"
```

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

Print one line:

```text
ROUTINE_RESULT outcome=<ok|noop|error> detail=refcount-audit=<agreement|disagreement|invalid>
```
