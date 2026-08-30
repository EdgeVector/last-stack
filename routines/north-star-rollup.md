---
name: north-star-rollup
cadence: hourly
description: Regenerate the North Star × column dashboard from the live board + brain NS projects; write markdown into brain `north-star-dashboard` and refresh the local HTML snapshot. Read-only on the board; write-only on the dashboard reference + HTML file. Never moves cards or ships code.
---

You are the **north-star-rollup** routine — the hourly North Star tracking mirror.
Run ONE pass, then exit.

Your ONE job: keep the durable brain reference `north-star-dashboard` and the
local HTML snapshot current against (1) every kanban card's `north_star` field
and (2) brain `project` records tagged/titled as North Stars. You are READ-ONLY
on the board and on product code. You never move cards, open PRs, file cards, or
edit North Star / `active-programs` prose.

This complements (does not replace):
- `program-rollup` — prose-membership auto blocks inside `active-programs`
- `program-driver` — promotes next program cards into `todo`; enforces terminal verification / NS completion
- `last-stack-north-star-completion-check` — terminal card status (also `--stdout completion` on the dashboard binary)
- `morning-sync` — human-gate briefing

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-north-star-rollup`),
**not** the skill frontmatter `name:`. Before any read/write, fail loudly if the
resolved path is empty or starts with `/automations/`. If the sandbox refuses
the path, note `memory_unwritable=<path>` in the heartbeat and continue.

## Hard safety rules
- NEVER kill / restart / reset the primary brain (`lastdbd`) or any forge node.
- If the board/brain is busy (`service_timeout`, "too many concurrent reads",
  "node did not respond"), report `busy-node skipped north-star-rollup` and EXIT.
  Do not run doctor/init.
- If the dashboard command times out but the previous brain/dashboard snapshot
  and HTML file are still present and non-empty, treat that as transient shared
  backpressure: heartbeat `noop reason=dashboard-timeout-prior-snapshot`
  and EXIT. Do not turn a one-pass refresh miss into a fleet error.
- No `sleep`-to-wait; one foreground pass then exit. Wrap long calls in `timeout`
  when available.
- Never call `last-stack-north-star-dashboard` directly for the refresh. Use
  `last-stack-north-star-dashboard-run`, which records the exit status on disk.
  The exit status of a bare call lives only in the tool result, and a lost tool
  result then reads as silence.
- Prefer the pure script over hand-assembled markdown — the script is the source
  of truth for counts and grouping.

## Tools
```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" brain kanban python3
```

Dashboard binary (in order):
1. `$last_stack/bin/last-stack-north-star-dashboard` if executable
2. else any path you were given for a checkout that contains the bin

HTML snapshot path (stable):
`$HOME/code/edgevector/north-star-dashboard.html`

Brain record (stable):
`north-star-dashboard` (type `reference`)

## Each run — do exactly this
1. **Preflight.** Confirm `brain` and `kanban` are on PATH. Run a cheap
   socket-safe read: `kanban list --column todo --json` or `kanban ping` when
   available. Do **not** use `brain list` for health or inventory (list is a
   SAMPLE, not a census). On busy-node errors, EXIT with noop.
2. **Regenerate.** Always go through the wrapper, never the bare binary:
   ```bash
   "$last_stack/bin/last-stack-north-star-dashboard-run" \
     --html "$HOME/code/edgevector/north-star-dashboard.html" \
     --timeout 900
   ```
   This 15-minute command budget leaves five minutes in the routine's
   20-minute run budget for confirmation, close-out, and the final heartbeat.

   The wrapper writes the outcome to a durable status file
   (`$HOME/.local/state/last-stack/north-star-dashboard/last-run.env`) before
   and after the generator runs, so the outcome survives a lost tool result.
   **Never classify this run from the tool result alone** — an empty tool
   result is not evidence of anything. Read the status file in step 3.
   The script:
   - collects board state from the board
   - point-reads brain projects for each card `north_star` slug (plus known
     aliases / active-programs seeds) — never `brain list` as membership
   - applies known NS aliases (e.g. legacy schema roadmap → shared-surface NS)
   - upserts `north-star-dashboard` and writes the HTML file
   If the wrapper returns `124` (timeout) or stderr contains a transient
   busy-node signal, do **not** turn the fleet red when a previous dashboard
   snapshot exists and is non-empty. Treat it as load/backpressure: update
   memory with the timeout, heartbeat
   `north-star-rollup <ISO-ts> noop reason=dashboard-timeout-prior-snapshot previous_html_bytes=<bytes>`,
   print the machine trailer using the ROUTINE_RESULT token followed by
   `outcome=<noop> detail=reason=dashboard-timeout-prior-snapshot`,
   and exit. Only use `error` for timeout/crash cases where no prior dashboard
   artifact exists or confirmation proves the artifact is empty/corrupt.
3. **Confirm.** First read the durable status file the wrapper wrote. It is the
   authoritative outcome of step 2:
   ```bash
   status_file="$HOME/.local/state/last-stack/north-star-dashboard/last-run.env"
   cat "$status_file"
   ```
   Classify from `dashboard_status`, not from what the tool result contained:
   - `ok` — continue to the brain confirmation below.
   - `timeout` — the command budget fired. Apply step 5.
   - `failed` / `killed` — `dashboard_diagnostic` names what failed. Report
     `error reason=dashboard-<status> exit=<dashboard_exit>` with that
     diagnostic, unless step 5 applies.
   - `running` — the wrapper itself died hard and never recorded an end. This is
     the old silent case, now named. Report
     `error reason=dashboard-wrapper-killed-no-exit started=<dashboard_started_at>`.
   - status file absent — step 2 never started. Report
     `error reason=dashboard-run-never-started`.

   Then point-read `brain get north-star-dashboard --type reference`
   (or `brain get north-star-dashboard`) and check the body head contains the
   current UTC hour's generated stamp (or today's date). The dashboard markdown
   currently renders the stamp inline as `**Generated:** \`<ISO>\``; older
   snapshots may use a plain `Generated: <ISO>` line. Accept both forms. A
   robust extraction is:
   ```bash
   generated=$(
     printf '%s\n' "$brain_out" |
       sed -n 's/^Generated:[[:space:]]*//p; s/^\*\*Generated:\*\*[[:space:]]*`\([^`]*\)`.*/\1/p' |
       head -1
   )
   ```
   Confirm the HTML file exists and is non-empty.
4. **Summarize** in one short paragraph: active NS count, top live-pressure
   North Stars (slug + live counts), unattributed live card count, HTML path.
   Mention any orphan `north_star` values (cards pointing at missing NS records).
   **Do not create North Star projects here** — that is `north-star-hygiene`
   (daily) / skill `north-star-hygiene`. You may note
   `HYGIENE_NEEDS_WORK=1` if `last-stack-north-star-dashboard --stdout hygiene`
   reports orphans so morning-sync can see the gap.
5. **Dashboard timeout handling.** This branch applies when step 3 read
   `dashboard_status=timeout` (or `dashboard_exit=124`) from the status file.
   Inspect the prior brain record and HTML snapshot first. If
   they are present and non-empty, report a `noop` with
   `reason=dashboard-timeout-prior-snapshot` and include the prior snapshot
   timestamp/counts in the summary. Treat this as temporary load, not a fleet
   error. Only use `error` for a timeout when there is no usable prior brain
   record or HTML snapshot to serve as the durable dashboard.
6. **Heartbeat** (last write/tool action):
   ```bash
   "$last_stack/bin/last-stack-brain-append-heartbeat" --line \
     "north-star-rollup <ISO-ts> <ok|noop|error> <one-line-outcome>"
   ```
7. **Final trailer, then stop.** After the heartbeat helper returns, do not run
   more tools. Respond with exactly one machine-readable line so routinesd can
   classify and close the run without waiting for fallback parsing: the
   `ROUTINE_RESULT` token followed by
   `outcome=<ok|noop|error> detail=<same-one-line-outcome>`.
   Then exit. For a successful regenerate, use `outcome=ok`. For a busy-node or
   prior-snapshot dashboard timeout skip, use `outcome=noop`. For a real script,
   brain write, or empty-dashboard failure, use `outcome=error`.

## Exit code semantics
- Successful regenerate → success (`ok`)
- Busy-node / unreachable → success noop (`noop reason=busy-node`) — do not fail
  the routine fleet for a temporary load spike
- Dashboard timeout with a usable prior brain record + HTML snapshot → success
  noop (`noop reason=dashboard-timeout-prior-snapshot`) — do not fail the
  routine fleet when the durable mirror is still available
- Script crash, brain put failure, empty HTML after claimed success → `error`
- `dashboard_status=failed|killed` in the status file → `error` with
  `dashboard_diagnostic` in the one-line outcome
- `dashboard_status=running` (wrapper died before recording an end) or a missing
  status file → `error reason=dashboard-wrapper-killed-no-exit` /
  `reason=dashboard-run-never-started`. Never report `ok` from an empty tool
  result; an empty tool result carries no outcome at all.

## Out of scope
- Promoting or moving cards
- Editing `active-programs` or individual North Star project bodies
- Publishing a Claude Artifact URL (local HTML + brain reference are enough;
  if an Artifact is later desired, redeploy to a single stable URL and record it
  in this same brain reference)

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
