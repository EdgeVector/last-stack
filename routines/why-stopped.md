---
name: why-stopped
cadence: every 2h (and on-demand)
description: Zero-LLM Class A–E factory freeze classifier — one-line why shipping stopped + optional Class A heal.
---

You are **why-stopped** — a **mechanical** factory diagnostic. Prefer the
zero-LLM loom graph (parallel install/node/forge/pickup probes); fall back
to the one-shot CLI. Do not burn a long agent budget re-deriving Class A–E.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq
```

## Run (bounded)

1. **Classify + best-effort Class A heal** via loom, then the one-shot CLI
   if loom is missing or the graph fails (exit 3):
   ```bash
   if ! "$last_stack/bin/last-stack-why-stopped-loom" --heal --json \
        | tee /tmp/why-stopped.json
   then
     "$last_stack/bin/last-stack-why-stopped" --heal --json \
       | tee /tmp/why-stopped.json
   fi
   ```
   Same `--key` within an hour (`why-stopped-YYYYmmddTHH`) resumes the
   existing exec — do not invent a second key.
2. **If classes include E (LastDB hot):** do **not** start generators or broad
   board scans. Heartbeat and EXIT.
3. **If classes include C (fold CI):** run
   ```bash
   "$last_stack/bin/last-stack-fold-ci-health" --page || true
   ```
4. **If classes include A and heal failed:** leave a one-line note in automation
   memory; do not restart lastdbd.
5. **If classes is `none`:** EXIT with noop — factory not frozen.

## Heartbeat / result

Prefer the CLI’s own heartbeat. Classify the stamp with
`last-stack-routine-outcome-classify --observer last-stack-why-stopped`
(or print the `ROUTINE_RESULT` token followed by
`outcome=<ok|noop|error> detail=<same-one-line-outcome>`).

- `ok` — classified (including `classes=unknown` or any Class A–F set)
- `noop` — classified healthy (`classes=none`) or only informational
- `error` — CLI missing or unusable

A finished classification is never `error` just because shipping is
frozen or the class set is unknown. Downstream red is the *subject*.

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

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
