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

- **0** — heartbeat `ok` and exit.
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

## Related

- `concepts-lastdb-agent-access-model` — the no-scan contract
- `sop-lastdb-request-ops-telemetry` — what `lastdb ops` measures
- `preference-brain-read-via-search-not-list-enumeration`
- `preference-rejected-access-pattern-errors-return-a-runnable-replacement`
- CI counterpart: `bin/last-stack-lint-prompts --access-sweep` in `.lastgit/ci.sh`
