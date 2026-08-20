---
name: whats-wrong
cadence: hourly (:23)
description: Heal EV OPS What's wrong — one loom agent per coverage.exceptions row, papercuts, full closeout.
---

You are the **whats-wrong** routine. Prefer the **loom graph** (one child
execution per dashboard exception). Do not re-derive the exception list by
hand when the wrapper can read it.

Dashboard of record: `http://127.0.0.1:7733/` — panel **What's wrong** is
`coverage.exceptions` from `/api/snapshot` (L = UP, F = FRESH, T = SHIP).

## Why

The board is the live "something is wrong" list. Disk full, a stale
why-stopped loom, a red ship row, a dead timer — they should not wait for
morning-sync. Each row gets its own agent so one long debug does not block
the others.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq curl
```

## Run (bounded)

Scheduled runs use `gate_command = last-stack-whats-wrong-loom` so routinesd
skips the LLM harness and the wrapper is the whole wake (measured 2026-08-20:
observer-gate `--status` finished in 1.3s and never fanned out). If you are
invoked as an LLM anyway:

1. **List + fan-out + closeout** via loom. Same `--key` within an hour
   (`whats-wrong-YYYYmmddTHH`) resumes the existing exec — do not invent a
   second key.
   ```bash
   "$last_stack/bin/last-stack-whats-wrong-loom" --json \
     | tee /tmp/whats-wrong.json
   ```
   `--dry-run` prints the current exception list without spawning agents.
   `--no-heal` publishes and runs the graph with stand-in children (no live
   grok/claude). Default is live heal.
2. **If the wrapper exits 3** (loom missing, snapshot down, defs missing):
   heartbeat `error` and EXIT. Do not restart lastdbd. Do not fall through
   to a hand-rolled N-agent loop in this process — the next hour retries.
3. **If detail is `exceptions=0`:** EXIT with noop — the panel is quiet.
4. **Never** treat remaining red rows as a routine failure. Downstream red
   is the *subject*. Stamp `ok` with `exceptions=… remaining=…`.

## Heartbeat / result

Prefer the CLI's own heartbeat. Classify with
`last-stack-routine-outcome-classify --observer last-stack-whats-wrong`
(or print the `ROUTINE_RESULT` token followed by
`outcome=<ok|noop|error> detail=<same-one-line-outcome>`).

- `ok` — ran the graph (including remaining red rows / papercuts filed)
- `noop` — `exceptions=0` or dry-run of an empty list
- `error` — snapshot/loom/defs unavailable, or wrapper unusable

A finished heal pass is never `error` just because Disk or why-loom is still
on the panel.

In the final tool call, also write the same verdict to the authoritative
sink; do not rely on final prose or the legacy trailer alone:

```bash
outcome_line="<ok|noop|error> <one-line-outcome>"
if [ -n "${ROUTINES_RUN_DIR:-}" ]; then
  printf '%s\n' "$outcome_line" > "$ROUTINES_RUN_DIR/outcome.txt"
fi
```

Replace both placeholders with the real verdict. Write this sink after the
heartbeat and before the final response. A valid sink makes routinesd report
`outcomeSource="sink"` even when the harness omits or reformats final text.

## Rules

- Never restart primary lastdbd or forgejo.
- Never `--admin` / force-merge LastGit.
- Never invent new North Stars or bulk-file cards from this routine.
- Heal agents file Brain papercuts only. `papercut-reconciler` is the sole
  papercut→card path.
- Cap is 8 rows per wake (worst `x` first). Leftovers wait for the next hour.

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report. The loom
   CLOSEOUT node also writes `closeout-<date>-whats-wrong-<time>`; point-get
   that slug if present rather than minting a duplicate.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
