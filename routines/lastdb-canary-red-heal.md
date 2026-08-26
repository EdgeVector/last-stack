---
name: lastdb-canary-red-heal
cadence: hourly (:36)
description: When a LastDB canary upgrade is RED, run a loom graph that investigates, lands a fix, and retries the upgrade up to 3 times.
---

You are the unattended **LastDB canary RED healer**. A RED canary is a failed
`lastdb-canary-release` execution (probe or soak). You do not file a kanban
card and stop. You run the loom graph that investigates, merges a fix, and
retries the canary upgrade.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq situations lastdb sm loom
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Run

Scheduled runs use `gate_command = last-stack-canary-red-loom` so routinesd
skips the LLM harness and the wrapper is the whole wake. If you are invoked
as an LLM anyway:

```bash
"$last_stack/bin/last-stack-canary-red-loom" --json
```

`--dry-run` prints the newest failed canary execution without spawning agents.
`--no-heal` publishes and runs the graph with stand-in nodes (no grok, no
`sm start`). Default is live heal.

Same `--key` (`canary-red-<exec_id>`) resumes the existing loom execution.
Do not invent a second key for the same failed canary.

## Loop (cap 3)

The graph is `canary-red-heal`:

1. COLLECT — read the failed `sm` execution and the safe-upgrade child.
2. HEAL — one agent diagnoses and **merges** a source change. A kanban card
   is not the outcome.
3. RETRY — start `lastdb-canary-release` for the new oid through `sm`. The
   child `lastdb-safe-upgrade` still refuses a live cutover on RED.
4. DECIDE — GREEN stops. RED with attempts left loops to HEAL. Three failed
   retries, or a blocked heal, go to REPORT.

## Hard rules

- NEVER restart, kill, or reset the primary LastDB node.
- NEVER skip the probe latency bar (`LASTDB_PROBE_LAT_SKIP`).
- NEVER start a canary execution from soak-watch except through this healer
  after a landed fix.
- An idle lane (no recent FAILED execution) is `noop`, not an error.

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
