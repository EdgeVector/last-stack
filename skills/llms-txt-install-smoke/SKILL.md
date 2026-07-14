---
name: llms-txt-install-smoke
description: |
  Dogfood the public first-time install path from https://thelastdb.com/llms.txt
  in a fully isolated sandbox (never touch the primary LastDB at ~/.lastdb).
  Use when asked to "smoke the llms.txt install", "verify first-run install",
  "fresh install still works", or when the scheduled `llms-txt-install-smoke`
  routine fires (daily). Prefer this skill over hand-deriving install steps.
---

# llms-txt-install-smoke

Continuous canary for **new-user install**: does following
[thelastdb.com/llms.txt](https://thelastdb.com/llms.txt) still produce a
working Brain + Kanban + Situations stack on macOS Apple Silicon?

This is **not** the real-data Mini boot canary (`lastdb-smoke-test` /
`lastdb-local-smoke-test`). That clones Tom's live data. This one builds a
**throwaway empty** LastDB home and walks the public install script.

## Hard rules

1. **Never** start/stop/restart Tom's primary `brew services lastdb` / `lastdbd`
   on `~/.lastdb`. Always use an isolated `HOME` + `LASTDB_HOME` + manual
   `lastdbd --data-dir …`.
2. **Never** write to the real `~/.brain`, `~/.kanban`, or `~/.situations`
   during the smoke — those must live under the sandbox `HOME`.
3. Prefer the automated script (below). Only hand-drive steps when debugging
   a RED run.
4. A RED run **must file** a kanban card (and a short brain `reference` for
   recurring papercuts). Chat-only summaries evaporate.
5. Honor `brain get sop-routine-shared-contract --type sop` when invoked from
   a routine (heartbeat LAST, always).

## Preferred path — run the script

From any checkout that has Last Stack skills installed (or from
`${LAST_STACK_ROOT:-$HOME/.last-stack}`):

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
# Prefer the skill's own script (works from worktrees too):
script="$(find "$last_stack/skills/llms-txt-install-smoke" -name run.sh 2>/dev/null | head -1)"
# Fallback if setup symlinked only SKILL.md:
script="${script:-$last_stack/skills/llms-txt-install-smoke/run.sh}"
bash "$script"
# optional: bash "$script" --keep   # leave sandbox dir for inspection
# optional: bash "$script" --json   # machine-readable summary on stdout
```

The script prints `VERDICT: GREEN` or `VERDICT: RED` and exits 0/1.

## What the smoke asserts (GREEN)

| Step | Pass criteria |
|------|----------------|
| Prereqs | `brew`, `bun` (or installable), `git`, `curl`, `lastdbd` on PATH |
| last-stack clone | shallow clone of public `EdgeVector/last-stack` into sandbox |
| setup | `./setup` exit 0 |
| install-apps | brain + kanban + situations CLIs on sandbox PATH (lastsecrets may skip if private) |
| daemon | isolated `lastdbd --data-dir $LASTDB_HOME` serves socket within 30s |
| health | `curl --unix-socket …/folddb.sock http://localhost/health` → `{"status":"ok"}` |
| brain first-run bootstrap | `brain init --grant-consent` exit 0 (setup, not a health check); config has **no** `:9001` |
| kanban first-run bootstrap | setup exit 0; `kanban list` shows default board |
| situations first-run bootstrap | setup exit 0 without pre-declared schema; `situations list` exit 0 |
| quick try | `brain concept new` + `brain get hello` succeeds; `brain ask "first note"` or `brain search "first note"` finds the note |

## On RED

1. Capture the script log path from stderr/stdout.
2. Classify:
   - **Docs lag** (public llms.txt wrong) → card on `EdgeVector/fold_db_website`
   - **Installer** → `EdgeVector/last-stack`
   - **App init** → `EdgeVector/brain` / `fkanban` / `situations`
   - **Daemon/socket** → `EdgeVector/fold` or homebrew-lastdb as appropriate
3. File one kanban card with evidence (command + exit + excerpt), tags
   `first-run,llms-txt-smoke`, priority P0/P1 if install is fully broken.
4. Dedupe: search board for open `llms-txt` / `first-run` cards before filing.

## Never

- `brew services restart lastdb` / kill primary `lastdbd`
- Point sandbox tools at real `~/.lastdb/data/folddb.sock`
- Treat a primary-brain busy timeout as a failed install smoke
- Ship product fixes from the scheduled routine — **file cards only** when
  running as a routine (interactive use of this skill may fix if Tom asked)

## Related

- Public install map: https://thelastdb.com/llms.txt
- Real-data Mini canary: skill `lastdb-smoke-test`
- Onboarding wizard UI: skill `onboarding-preview`
