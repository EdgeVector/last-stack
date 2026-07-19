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

## Do this

1. Read the skill playbook (one tool call path):
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   # skill lives under last-stack after setup
   test -f "$last_stack/skills/llms-txt-install-smoke/SKILL.md"
   ```
   Follow **`llms-txt-install-smoke`** — prefer its `run.sh`.

2. Run the isolated smoke (never brew-services / never real `~/.lastdb`):
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   "$last_stack/bin/last-stack-cli-preflight" git curl brew lastdbd bun || true
   bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --json
   ```
   Capture exit code and `VERDICT: GREEN|RED`.

3. On **GREEN**: do not file cards. Heartbeat and exit.

4. On **RED**:
   - Dedupe with `kanban list --column todo --json` and
     `kanban list --column doing --json` first, checking for matching
     `llms-txt` / `first-run install` cards. `kanban search` is optional; if it
     returns `full_schema_scan_not_allowed`, continue with the scoped reads.
   - File or update **one** card per distinct failure cluster (not one per log line).
   - Tags: `first-run`, `llms-txt-smoke`, plus the owning subsystem
     (`brain` / `kanban` / `situations` / `last-stack` / `website`).
   - Repo must be bare `owner/name` on its own line.
   - Include evidence: failing step name from the script + short excerpt.
   - Priority: P0 if health/init completely broken; P1 if a single app fails;
     P2 for docs-only / config messaging.

5. Heartbeat LAST (always):
   ```text
   llms-txt-install-smoke <ISO-ts> <ok|error> <GREEN|RED one-line summary>
   ```
   Append via the contract's heartbeat recipe on `routine-heartbeats`.

## Safety floor

- **Never** restart, kill, or reconfigure the primary `lastdbd` / brew service.
- **Never** point the smoke at `~/.lastdb/data/folddb.sock`.
- **Never** ship code from this routine — file cards only.
- Optional private apps (lastsecrets) may skip without RED if the installer
  already treats them as optional.

## Related

- Skill: `llms-txt-install-smoke`
- Distinct from Mini real-data canary: `lastdb-local-smoke-test` / skill `lastdb-smoke-test`
