---
name: revenant-watch
cadence: daily
description: Daily Revenant Watch — session-miner profile that surveys agent transcripts for settled-dead product truths agents still act on (Brain-only findings + priority ledger; no board spam).
---

You are running the unattended **Revenant Watch** routine for the EdgeVector
workspace (`<WORKSPACE>`). Each run starts fresh.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-revenant-watch`),
**not** the skill frontmatter `name:`.

## Mission

Once a day, survey agent session transcripts for **revenants**: agents acting as
if a settled-dead product truth is still alive (example: building the full-DB
React app after that UI was removed). File prioritized findings to **Brain
only** — never papercut/board cards from this routine.

This is a **session-miner profile**, not a new peer engine
([[preference-freeze-new-routine-engines]]).

## Distinct from siblings

| Sibling | Lane |
|---------|------|
| `papercut-reconciler` / `papercuts` | Process friction → Brain papercuts → board later |
| `self-improvement-loop` / `friction-patterns` | Upgrade agent tooling |
| `capture-knowledge-to-brain` / `owner-statements` | Capture Tom's durable statements |
| `daily-retro-prevention` / `incidents` | Biggest bites + prevention |
| **You (`revenant-watch`)** | Stale **world model** vs settled canon |

## Standing rules

```bash
brain get sop-routine-shared-contract --type sop
brain get sop-revenant-watch --type sop
# optional override profile:
brain get miner-profile-revenant-watch --type reference 2>/dev/null || true
```

If the SOP conflicts with this prompt, the SOP wins.

Generator backpressure (optional, same helper as other generators):

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
if [ -x "$last_stack/bin/last-stack-generator-preflight" ]; then
  "$last_stack/bin/last-stack-generator-preflight" revenant-watch || exit 0
fi
```

## Step 1 — Run session-miner

Follow the **session-miner** skill with:

```text
profile=revenant-watch
window_hours=24
mode=apply
```

If apply is too hot / node busy, fall back once to `mode=report-only` and
heartbeat `noop node-busy report-only`; do not restart LastDB.

### Profile contract (won't-undo for this routine)

1. **Survey** all harness transcript roots session-miner already reaches.
2. **Extract** product claims in plans/actions (what the agent believes is true
   about the product and is acting on).
3. **Ground truth** = Brain canon only (won't-undo, standing preferences,
   retired surfaces, closed North Stars). Map claims to topics.
4. **Open-work exemption:** if an open kanban card or active North Star owns
   that topic/area, **skip** (in-flight is not a revenant).
5. **Conservative:** flag only clear contradictions of settled-dead canon with
   no open-work cover. Soft hunches stay quiet.
6. **Classify** with the deterministic helper when available:

```bash
# after building a case JSON of claims + canon + open_work:
"$LAST_STACK_ROOT/bin/last-stack-revenant-classify" /tmp/revenant-case.json --verbose
```

7. **Output (apply) — Brain only:**
   - Upsert `revenant-<topic>` (`type: reference`, tag `revenant`) — search first,
     update in place.
   - Append a dated block to `revenant-watch-ledger` (`type: reference`) with a
     priority-ordered list for the day.
   - **Never** file kanban cards, papercuts, or open PRs from this miner.

## Step 2 — Heartbeat

Write a short heartbeat (shared contract):

```text
revenant-watch <ISO-UTC> ok scanned=<n> flagged=<n> skipped_inflight=<n> ledger=revenant-watch-ledger
```

or

```text
revenant-watch <ISO-UTC> noop reason=<…>
```

## Anti-patterns

- Do not invent a parallel transcript engine outside session-miner.
- Do not file board cards "to be helpful."
- Do not treat active milestone/NS work as a revenant.
- Do not restart `lastdbd` / primary brain for timeouts.
- Do not use `brain list` as a census for open papercuts/canon completeness;
  use targeted `brain get` + known seeds / board point reads.
