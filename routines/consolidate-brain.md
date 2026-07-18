---
name: consolidate-brain
cadence: daily
description: Conservative daily consolidation of the brain — fix lying statuses, archive completed/junk/duplicate records, keep the driving index current against the board. Status-and-prose only; never edits record bodies wholesale, never ships code.
---

Objective: keep your **brain** (the long-lived notes store that drives
development) consolidated and able to drive work. Run ONE conservative
consolidation pass. This routine only adjusts record *status* and curates the
driving index prose; it does NOT author code or file board cards (other routines
do that).

Read first (don't skip):
- The convention note that explains your consolidation rules, if you keep one.
- The driving index (`<brain get> active-programs`).

## Scheduled-shell setup
Scheduled shells can start with a stripped PATH. Before any CLI-heavy work,
resolve Last Stack once, source its prelude, and preflight the tools you will
use:

```bash
last_stack="${LAST_STACK_HOME:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git jq <brain-cli> <board-cli> || true
```

Invoke Last Stack helpers by absolute path, for example
`"$last_stack/bin/last-stack-active-programs-guard"`. Do not rely on bare helper
names such as `last-stack-active-programs-guard`; they may not be on the
scheduled harness PATH.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-pickup`),
**not** the skill frontmatter `name:` (e.g. not bare `kanban-pickup`). Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly. If the
sandbox refuses the path, note `memory_unwritable=<path>` in the heartbeat and
continue — do not fail the whole run.

## CRITICAL safety rules
- The node hosting your brain is your live data. NEVER kill, restart, reset,
  clean, or stash anything. Read + status writes ONLY.
- Change status with a dedicated status command (`<brain status> <slug>
  <newstatus> --type <type>`) — this updates status IN PLACE and preserves the
  body. NEVER use a full-body `put` to change a status (a put without the full
  body wipes it).
- Archiving is reversible if your store is append-only, but don't churn. When
  genuinely uncertain whether a record is still live, KEEP it.

## Per-type "archive" enum
Statuses differ by record type — use your store's terminal enums, e.g.:
- project → `archived` (or `done`/`cancelled` if that's the true terminal state)
- concept / agent / design → `archived`
- preference → `superseded`   • reference → `archived` (or `broken` for a dead
  link)   • spike → `concluded`

## Steps
1. **Fix lying statuses.** For each live type, list non-terminal records and scan
   title+body for terminal signals: shipped / merged / complete / done /
   cancelled / abandoned / superseded / resolved / rejected / retired. For any
   whose body clearly says the work is finished, flip to the correct terminal
   enum. This is the most important step — a status field that lies is what makes
   the brain undrivable.
2. **Archive newly-completed task-logs & junk.** Single-PR task-logs, run logs,
   "Phase N" tasks, audit/execution logs that completed → archive. Junk test
   records (bare slugs, probe/smoketest scratch, round-trip tests) → archive.
3. **Collapse duplicates.** If two records cover the same topic, archive the
   weaker/older copy and keep the canonical one. Don't merge bodies — just archive
   the dupe.
4. **Keep the driving index current — PROSE ONLY.** Read the board with
   sequential column previews (`<board CLI> list --column todo --json`, then
   `doing`, `review`, and `backlog` as needed) and reconcile the driving index
   against it — each active program should map to its board epic/cards with an
   honest **Why / decision / Next move**. Use `<board CLI> show <slug> --json`
   for the one card whose full body you need; do not use broad/full-body board
   reads.
   Before editing prose, stage the active-programs body and a board snapshot with
   at least `slug` and `column`, then run
   `<last-stack>/bin/last-stack-active-programs-guard stale-report --active
   <active-body> --board <snapshot-json>`. Treat `drained` reports as the primary
   candidate list for retiring stale program prose or moving it to the completed
   archive; treat `mixed` reports as ordinary progress notes and keep the live
   next card visible.
   Convention: **brain = why/decision; board = what's in flight; if the index
   disagrees with the board, the board wins.** Curate the human prose: add a
   newly-started program, retire a finished one, fix a stale next-move, name the
   cards that move each program. If anything changed, write the index body back
   via a `body_path` temp file (don't inline a long body).
   - **Do NOT hand-edit the per-program `rollup:start`…`rollup:end` auto-status
     blocks** — those are owned and refreshed hourly by `program-rollup`. Preserve
     them verbatim. If you add a brand-new program section, leave it block-free
     and `program-rollup` seeds it next run.
5. **Verify every write.** Writes to a shared node can silently fail under load —
   after each status change, point-read it back; retry once if it didn't stick.

Scale note: once your brain is fully consolidated, daily deltas should be SMALL —
usually a handful of newly-terminal records. If you find yourself wanting to
archive dozens, slow down and re-check your criteria; default to KEEP. You can do
the whole pass inline; no need to fan out subagents for a small delta.

## Output
A short summary: counts re-statused/archived by type, any duplicates collapsed,
what changed in the driving index, and a brief "left for human review" list of
anything ambiguous you deliberately did NOT touch.
