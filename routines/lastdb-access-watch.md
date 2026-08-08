---
name: lastdb-access-watch
cadence: weekly
description: Zero-LLM detector — name any client issuing scan-shaped reads against the primary, from lastdb ops telemetry.
---

# lastdb-access-watch

**Zero-LLM.** Read-only. Runs one control-plane read and reports. Cites
`sop-routine-shared-contract`; that SOP wins on any conflict.

## Why

LastDB is Dynamo-style: **Get O(1), range-under-one-hash O(log M), no scan**
(`concepts-lastdb-agent-access-model`). The CI prompt-lint
(`last-stack-lint-prompts --access-sweep`) stops banned access patterns from
*landing in this repo*. It cannot see a read issued from an agent session,
another repo, or a flag combination nobody linted.

This routine detects the behaviour instead of the source text. The physical
signature of a scan-shaped read is **cold shard loads per call**: a keyed point
read touches ~1 shard, an unkeyed or wide read touches many. That signal is
CLI-independent — it catches a bad access pattern no matter which verb, repo,
or session produced it.

## Do

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude" 2>/dev/null || true
"$last_stack/bin/last-stack-lastdb-access-watch"
```

Exit codes: `0` clean · `1` findings · `2` **unknown** (could not parse, node
busy, or `lastdb` missing).

Alerting runs on the **recent (ring) window** by default. The lifetime table is
a process-lifetime AVERAGE and therefore **dilutes**: measured 2026-08-08, one
unchanged read went 26 → 13 → 6 loads/call purely as its call count grew
175 → 730, clearing the default threshold while still being the worst per-call
kanban query on the node. Alerting on that average lets a persistent offender
walk itself out of sight.

Neither window proves absence, so do not read "ok" as "nothing wrong":

- **ring** cannot dilute, but it is a TOP-N table sorted by *total* loads — a
  high-per-call, low-count read can rank below a heavy mutation and never be
  printed.
- **lifetime** dilutes, so a lifetime *finding* is strong evidence (it survived
  dilution) while a lifetime *clean* is weak.

A clean ring run still prints a **NOTE** for any lifetime row that looks like a
diluted persistent offender. Treat those as leads, not findings — they do not
change the exit code. Re-check one with `--window lifetime`, and cross-check by
cost rather than per-call with `lastdb ops` (Top by total time).

- **0** — heartbeat `ok` and exit. If the run printed dilution NOTEs, name them
  in the heartbeat line so a recurring lead is visible across weeks.
- **2** — heartbeat `noop` with the reason. This is NOT a finding and NOT an
  outage. A busy node is load/backpressure. Do not escalate, do not restart, do
  not reindex. Re-runs next cadence.
- **1** — file work (below), then heartbeat `ok` naming the offenders.

## On findings

File or update **one** deduped `Kind: pr` card on `EdgeVector/fold` (or the repo
that owns the offending client) per distinct `client + schema`. Search the board
first — this runs weekly and the same offender will recur until it is fixed.

The card must carry the measured evidence, since that is what makes it
actionable: `client`, `schema`, `loads/call`, `count`, and the window
(`ring` = recent, `lifetime` = process totals).

The fix is **an access pattern, not a tuning knob**: design a second schema
dual-written by the app, keyed for that query (the Dynamo GSI idea), rather than
widening the existing read. Cite `concepts-lastdb-agent-access-model`.

## Never

- Never reindex, restart, or kill the primary in response to a finding. A
  scan-shaped read is a design defect in the caller, not node corruption.
- Never treat exit 2 as clean. The detector refuses to print "ok" from a dump it
  could not parse, precisely so a broken watcher cannot read as a healthy system.
- Never conclude an offender was FIXED from a clean run alone. The per-call
  number falls as call count grows even when nothing changed. Confirm a fix with
  `lastdb ops` total time for that client+schema, not with this detector's
  threshold.

## Blind spot: writes

This detector reports **reads only** — a mutation legitimately touches many
shards, and flagging writes would bury the read signal. So it will not surface a
slow write path even when that is the dominant cost on the node. On 2026-08-08
`client=kanban kind=mutation schema=39a0424f` ran avg 61s / max 21min and was
the #2 consumer of node time, invisible to this routine. When the node feels
slow and this reports clean, read `lastdb ops` **Top by total time** before
concluding anything.

## Related

- `concepts-lastdb-agent-access-model` — the no-scan contract
- `sop-lastdb-request-ops-telemetry` — what `lastdb ops` measures
- `preference-brain-read-via-search-not-list-enumeration`
- `preference-rejected-access-pattern-errors-return-a-runnable-replacement`
- CI counterpart: `bin/last-stack-lint-prompts --access-sweep` in `.lastgit/ci.sh`
