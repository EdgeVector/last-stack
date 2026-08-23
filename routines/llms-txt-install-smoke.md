---
name: llms-txt-install-smoke
cadence: daily
description: Daily isolated dogfood of the public thelastdb.com/llms.txt first-run install path; file cards on RED; never touch primary LastDB.
---

You are running an unattended daily routine. Objective: prove that a **brand-new
user** can still install LastDB from the public install map at
https://thelastdb.com/llms.txt (Brain + Kanban + Situations first-run).

**Shared contract:** fetch `brain get sop-routine-shared-contract --type sop` at
run start and honor it — heartbeat LAST always, primary-brain guardrail,
FILE-don't-ship (this routine does **not** ship product code), dedupe-before-filing,
scheduled-run shell discipline. If this prompt conflicts with it, the contract wins.

## Hard rule — FOREGROUND ONLY (won't-undo)

The smoke **must** complete inside **one foreground Bash tool call**.

**Forbidden (treat any of these as RED / incomplete):**

- `run_in_background`, background Bash, or any "run in background / you'll be notified"
- `ScheduleWakeup`, sleep-poll, or ending the turn while smoke is still running
- Claiming GREEN without a tool result that contains a literal `VERDICT: GREEN` line
  from `run.sh` (or the wrapper)
- Exiting with exit code 0 from the harness when you never captured `VERDICT:`

**Why:** On 2026-08-04 a scheduled fire backgrounded `run.sh`, ended the turn in
~60s, the harness killed the background task, and routines recorded
`exitCode=0` / `outcome=unknown` with **no VERDICT and no heartbeat**. That is
a fake success. Incomplete smoke = **error RED incomplete**, never ok.

Smoke wall time is typically **8–15 minutes**. Use a long block/timeout on that
single Bash call (at least **40 minutes** / 2400000ms). Do not split the smoke
across tools.

## Do this

1. Optional preflight (short foreground commands OK):
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   test -f "$last_stack/skills/llms-txt-install-smoke/SKILL.md"
   test -x "$last_stack/skills/llms-txt-install-smoke/run.sh" \
     || test -f "$last_stack/skills/llms-txt-install-smoke/run.sh"
   . "$last_stack/bin/last-stack-shell-prelude"
   "$last_stack/bin/last-stack-cli-preflight" git curl brew lastdbd bun || true
   ```

2. **Run the isolated smoke in ONE foreground Bash call** (never brew-services /
   never real `~/.lastdb`). Prefer the wrapper (enforces VERDICT + RESULT line):

   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   bash "$last_stack/skills/llms-txt-install-smoke/routine-run.sh"
   # Fallback if wrapper not yet installed:
   # bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --json
   # echo "EXIT_CODE=$?"
   ```

   Capture from the tool result:
   - process exit code of the wrapper/`run.sh` (0 = GREEN, non-zero = RED)
   - a line matching `VERDICT: GREEN` or `VERDICT: RED`
   - optional JSON line with `"verdict":"GREEN"|"RED"`

   **If the tool result has no `VERDICT:` line** → treat as
   `RED incomplete-no-verdict` (even if Bash exit was 0 or the command was
   backgrounded/killed). Heartbeat `error`, do not claim success.

3. On **GREEN** (`VERDICT: GREEN` present and exit 0): do not file cards.
   Heartbeat and print the machine trailer, then exit.

4. On **RED** (including incomplete / killed / no VERDICT):
   - Dedupe with `kanban list --column todo --json` and
     `kanban list --column doing --json` first, checking for matching
     `llms-txt` / `first-run install` cards. `kanban search` is optional; if it
     returns `full_schema_scan_not_allowed`, continue with the scoped reads.
   - File or update **one** card per distinct failure cluster (not one per log line).
   - Tags: `first-run`, `llms-txt-smoke`, plus the owning subsystem
     (`brain` / `kanban` / `situations` / `last-stack` / `website`).
   - Repo must be bare `owner/name` on its own line.
   - Include evidence: failing step name from the script + short excerpt.
     For incomplete runs, evidence = "no VERDICT; background/killed/timeout".
   - Priority: P0 if health/init completely broken or smoke incomplete with no
     verdict; P1 if a single app fails; P2 for docs-only / config messaging.

5. Heartbeat LAST (always), then machine trailer:

   ```text
   llms-txt-install-smoke <ISO-ts> <ok|error> <GREEN|RED one-line summary>
   ```

   Append via the contract's heartbeat recipe on `routine-heartbeats`.

   Final line of your response (routines outcome parser):

   ```text
   RESULT: ok GREEN pass=N/N
   ```
   or
   ```text
   RESULT: error RED <fails-or-incomplete>
   ```

## Safety floor

- **Never** restart, kill, or reconfigure the primary `lastdbd` / brew service.
- **Never** point the smoke at `~/.lastdb/data/folddb.sock`.
- **Never** ship code from this routine — file cards only.
- Optional private apps (lastsecrets) may skip without RED if the installer
  already treats them as optional.

## Related

- Skill: `llms-txt-install-smoke` (and `routine-run.sh` wrapper)
- Distinct from Mini real-data canary: `lastdb-local-smoke-test` / skill `lastdb-smoke-test`

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
