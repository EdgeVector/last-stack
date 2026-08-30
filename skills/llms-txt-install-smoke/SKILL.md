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
working Brain + Kanban + Situations + Search stack on macOS Apple Silicon?

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
6. **Foreground only.** Never background `run.sh` / `routine-run.sh`. Never end
   the agent turn while the smoke is still running. Incomplete / killed /
   no-`VERDICT` runs are **RED**, never success. (2026-08-04 scheduled fire
   backgrounded smoke, harness exit 0, no VERDICT — false success.)

## Preferred path — run the script

From any checkout that has Last Stack skills installed (or from
`${LAST_STACK_ROOT:-$HOME/.last-stack}`):

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
# Scheduled routine: mechanical wrapper (VERDICT + RESULT: trailer required)
bash "$last_stack/skills/llms-txt-install-smoke/routine-run.sh"
# Interactive / debug:
# bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --json
# bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --keep
```

`run.sh` prints `VERDICT: GREEN` or `VERDICT: RED` and exits 0/1.
`routine-run.sh` additionally prints a `RESULT: ok|error …` trailer and exits
**2** if no VERDICT line was produced (incomplete).

Wall time is 6–9 minutes. The whole design fits under the agent Bash tool's
hard 600-second foreground cap, so give that single call the tool maximum
(600000 ms) — not a longer figure the tool cannot honor.

## What the smoke asserts (GREEN)

| Step | Pass criteria |
|------|----------------|
| Prereqs | `brew`, `bun` (or installable), `git`, `curl`, `lastdbd` on PATH |
| Host OBS strip | After sandbox `HOME`/`LASTDB_HOME` are set, `run.sh` unsets host `OBS_SENTRY_*` / `SENTRY_*` so routinesd injectors (e.g. `lastsecrets://` DSN) never reach the isolated `lastdbd`. Brand-new users do not carry those vars. |
| last-stack clone | shallow clone of public `EdgeVector/last-stack` into sandbox |
| setup | `./setup` exit 0 |
| install-apps | brain + kanban + situations + search CLIs on sandbox PATH; uses `--no-brew` so smoke never rewrites the host service plist |
| brew-service home | **read-only** inspect of installed `homebrew.mxcl.lastdb.plist` (never `brew services start`): no `/tmp` or `/var/folders` freeze of `HOME`/`LASTDB_HOME`; prefer `lastdbd-service` runtime wrapper; legacy bare `lastdbd` only if env is login home or unset |
| daemon | isolated `lastdbd --data-dir $LASTDB_HOME` serves socket within 30s |
| health | `curl --unix-socket …/folddb.sock http://localhost/health` → `{"status":"ok"}` |
| brain first-run bootstrap | `brain init --grant-consent` exit 0 (setup, not a health check); config has **no** `:9001` |
| kanban first-run bootstrap | setup exit 0; `kanban list` shows default board |
| situations first-run bootstrap | setup exit 0 without pre-declared schema; `situations list` exit 0 |
| search first-run bootstrap | `search init --quiet` exit 0, matching the public install sequence before semantic retrieval |
| quick try | `brain concept new` + `brain get hello` succeeds; `brain ask "first note"` or `brain search "first note"` finds the note |

## Time bounds

The smoke runs in one foreground call. The agent Bash tool kills a foreground
call at 600 seconds. A killed run gives no `VERDICT:` line, so it tells you
nothing. Two mechanisms prevent that.

**One global budget.** `run.sh` arms a deadline at start. Every bounded call
gets the smaller of its own bound and the time left. When the budget is spent,
each remaining call gets a one-second bound and fails immediately, so the run
always reaches its footer and prints a real `VERDICT: RED`.

**Live breadcrumbs.** `run.sh` sends ordinary output to a log inside the
disposable sandbox. Step markers and each OK/FAIL line also go to the real
stderr with an elapsed-seconds stamp. A killed run therefore still names the
last step it reached.

**An outer backstop.** `routine-run.sh` runs `run.sh` under one wrapper bound
(570s) above the internal budget and below the tool cap, so an unbounded new
step still ends in a `RESULT:` trailer.

**Cheap teardown.** The `VERDICT` prints before cleanup, so a slow teardown
spends the caller's remaining cap after the answer already exists. A 2026-08-30
reproduction reached `VERDICT: RED` at 376s and was killed at 570s still inside
`rm -rf` of the sandbox, so the caller read a timeout instead of the verdict.
The daemon stop is bounded, and the sandbox is renamed aside — one inode
operation — with its removal detached. A directory that survives anyway is
reaped at the start of a later run.

| Variable | Default | What it bounds |
|---|---|---|
| `SMOKE_TOTAL_BUDGET_SECS` | 540 | The whole run. Set 0 to disable for interactive debugging. |
| `INSTALL_TIMEOUT` | 240 | Each of clone, setup, install-apps. |
| `APP_INIT_TIMEOUT` | 120 | Each brain/kanban/situations init and list. |
| `QUICK_TRY_TIMEOUT` | 60 | Each quick-try call. |
| `SMOKE_WRAPPER_TIMEOUT_SECS` | 570 | `routine-run.sh`'s outer backstop on the whole of `run.sh`. |
| `SMOKE_DAEMON_STOP_SECS` | 15 | Waiting for the isolated `lastdbd` to exit during teardown. |
| `SMOKE_SANDBOX_RM_SECS` | 45 | Fallback inline `rm -rf`, used only when the rename fails. |
| `SMOKE_SANDBOX_REAP_MINS` | 120 | Age above which a leftover sandbox is reaped at start. |

CAUTION: raise `SMOKE_TOTAL_BUDGET_SECS` above 570 only when you run the smoke
outside the agent tool. Inside it, a larger budget returns the run to the
silent-kill failure this design removes.

## On RED

1. Capture the script log path from stderr/stdout.
2. Classify:
   - **Docs lag** (public llms.txt wrong) → card on `EdgeVector/fold_db_website`
   - **Installer** → `EdgeVector/last-stack`
   - **App init** → `EdgeVector/brain` / `fkanban` / `situations`
   - **Daemon/socket** → `EdgeVector/fold` or homebrew-lastdb as appropriate
   - **Incomplete canary** (no VERDICT / background killed) → `EdgeVector/last-stack`
     (routine harness / prompt discipline), not product install, unless product
     steps also failed
3. File one kanban card with evidence (command + exit + excerpt), tags
   `first-run,llms-txt-smoke`, priority P0/P1 if install is fully broken.
4. Dedupe: search board for open `llms-txt` / `first-run` cards before filing.

## Never

- `brew services restart lastdb` / kill primary `lastdbd`
- Point sandbox tools at real `~/.lastdb/data/folddb.sock`
- Treat a primary-brain busy timeout as a failed install smoke
- Background the smoke and treat harness exit 0 as GREEN
- Ship product fixes from the scheduled routine — **file cards only** when
  running as a routine (interactive use of this skill may fix if Tom asked)

## Related

- Public install map: https://thelastdb.com/llms.txt
- Real-data Mini canary: skill `lastdb-smoke-test`
- Onboarding wizard UI: skill `onboarding-preview`
