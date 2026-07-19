---
name: north-star-hygiene
description: |
  Keep brain North Star projects in sync with kanban card `north_star` fields.
  Detects orphan NS slugs (cards point at a missing brain project), materializes
  real `project` North Star records from board + active-programs + designs,
  clears high-confidence mis-tags, and refreshes the north-star-dashboard.
  Use when: "orphan north star", "fold discovery's orphan NS", "north star
  hygiene", "cards point at missing north star", "create the north star
  project", dashboard shows orphan NS, or the scheduled north-star-hygiene
  routine fires. Complements north-star-rollup (matrix only) — this one WRITES
  missing NS projects.
---

# north-star-hygiene — materialize orphan North Stars

## Why this exists

Cards carry `north_star: <slug>`. Grouping lives in **brain `project` records**,
not board umbrellas. When cards cite a slug that has no brain project, the
dashboard marks it **orphan**, completion checkpoints fall into
`fkanban-orphan-completion-checkpoints`, and program-driver cannot resolve
ownership.

**Nothing else creates those projects.** `north-star-rollup` only *reports*
orphans. This skill/routine is the fixer.

Reference incident: Discovery cards used `north-star-lastdb-deliver-data-slices`
for days with no brain project until an agent folded design + board state into
a real NS record (2026-07-14).

## Modes

| Mode | When | Writes |
|------|------|--------|
| **REPORT** | User asks "what's orphan?" / dry-run | none (stdout + optional files) |
| **FIX** | User asks to fold/create / scheduled routine | brain NS projects, mistag clears, dashboard refresh |

Default when invoked by the **routine** = **FIX**. Default when user is
browsing only = **REPORT** unless they say "fix" / "create" / "fold".

## Hard rules

- NEVER kill/restart the primary brain (`lastdbd`). Busy-node → exit noop.
- **Never invent a new NS slug** when cards already share one — create the
  project at the **exact** `north_star` field value (after known aliases).
- Prefer **one** NS per product program; use aliases in
  `last-stack-north-star-dashboard` (PR) when two slugs mean the same thing —
  do not silently re-point every card to a prettier name in hygiene runs.
- Do **not** invent North Stars for unattributed cards (empty `north_star`).
  That is a filing/groom problem, not hygiene.
- Mis-tag clears: only when heuristic + human-readable title/slug clearly
  disagree with the NS (e.g. `sentry-triage-*` under Discovery). When in doubt,
  **report only**.
- Multi-line brain bodies: `brain put` via **stdin** (or staged file piped),
  never `--body "$(cat …)"`.
- Clearing `north_star` requires **both** `--north-star ""` **and** removing any
  `North Star:` body header line (kanban re-hydrates the field from the body).

## Tools

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" brain kanban python3
dash_bin="$last_stack/bin/last-stack-north-star-dashboard"
```

## REPORT mode

```bash
"$dash_bin" --stdout hygiene
# or machine-readable:
"$dash_bin" --hygiene-json /tmp/ns-hygiene.json --stdout none
```

Read `hygiene.orphan_north_stars_live`, `orphan_north_stars_done_only`,
`mistag_candidates`, `summary`. Present a short table to the user. Stop if
REPORT-only.

## FIX mode — one pass

### 1. Detect

```bash
work="$(mktemp -d "${TMPDIR:-/tmp}/ns-hygiene.XXXXXX")"
"$dash_bin" --hygiene-json "$work/hygiene.json" --json-out "$work/model.json" --stdout none
```

If `summary.needs_work` is false and you are not also materializing done-only
orphans: refresh dashboard (step 5), heartbeat `noop`, exit.

### 2. Materialize each orphan NS with live cards (priority order)

For each entry in `orphan_north_stars_live` (then, if time remains, done-only):

1. **Skip if it appeared since detect:**
   `brain get <slug> --type project` succeeds → skip.
2. **Gather evidence (cheap first):**
   - `kanban show <card>` for up to ~8 live cards (titles + GOAL/END STATE)
   - `brain get active-programs` — section that mentions the slug
   - `brain ask "<slug> <product keywords from card titles>"` (limit 5)
   - any design/concept the ask returns (e.g. Discovery architecture design)
3. **Write the project** with stdin:

```bash
slug="<exact orphan slug>"
body_file="$(mktemp)"
export NORTH_STAR_SLUG="$slug"
cat >"$body_file" <<'EOF'
---
type: project
slug: __NORTH_STAR_SLUG__
title: 🌟 North Star — <short product name from evidence>
status: in_progress
tags: [north-star, <product tags>]
---

# 🌟 North Star — <name>

**Slug (stable card field):** `__NORTH_STAR_SLUG__`
**Repo / venue:** <from cards>
**Related:** [[active-programs]], <designs if any>

## End state
<5–8 bullets: product done, not libraries. Pull from card DONE-WHEN / design.>

## Terminal verification
- **Card:** `<terminal-card-slug>`
- **Shape:** `pr` runnable harness | `validation` DONE-WHEN
- **Done means:** <one line>
(See [[sop-north-star-terminal-verification]]. If no card exists yet, leave
`Card: TBD` and let program-driver file one.)

## Completion proof
- Landed (board done): <list>
- Open (live): <list>

## NOT driving
<anti-goals from standing directives / card OUT OF SCOPE>

## Board note
Card field `north_star: __NORTH_STAR_SLUG__` is canonical — do not invent a second slug.
EOF
perl -0pi -e 's/__NORTH_STAR_SLUG__/$ENV{NORTH_STAR_SLUG}/g' "$body_file"
brain put "$slug" --type project <"$body_file"
rm -f "$body_file"
brain get "$slug" --type project | head -20   # confirm
```

Template quality bar (same as a hand-written NS like CodeRings / Discovery):

- End state is **product outcomes**, not a file list
- Names the repo / LastGit venue when known
- Lists current live + done cards so the next agent can drive
- Explicit **NOT driving** so scope does not creep

If evidence is too thin to write a real end state: still create a **stub** with
status `in_progress`, title from the dominant card theme, body saying
`STUB — needs end-state fill from <card list>`, and tags `north-star, stub`.
Better a stub than an orphan.

### 3. Mistags (high confidence only)

For each `mistag_candidates` entry, **confirm** by reading the card:

- Clear only if the card is obviously not that product (different subsystem in
  title/slug and body has no real claim to the NS).
- To clear:

```bash
# strip North Star: body lines, then:
printf '%s' "$new_body" | kanban add "$slug" --column "$col" --title "$title" --north-star ""
kanban show "$slug" --json   # north_star must be empty
```

Do not re-point to a different NS unless body/title already name that NS.

### 4. Optional: done-only orphans

If `orphan_north_stars_done_only` is non-empty and live orphans are cleared:
create stub or full records for done-only slugs with `total >= 3` so completion
checkpoints resolve. Skip one-off noise slugs (`fleet reliability after …`
prose mistakes) — clear the card field instead if the slug is garbage.

### 5. Refresh dashboard

```bash
timeout 300 "$dash_bin" \
  --put-brain \
  --html "${NORTH_STAR_HTML:-$HOME/code/edgevector/north-star-dashboard.html}" \
  --stdout none
```

If this refresh times out or reports transient busy-node/backpressure after the
detected hygiene writes already succeeded, confirm a previous dashboard brain
record or HTML snapshot exists and is non-empty, then continue to heartbeat the
actual hygiene result. Use `ok` if projects were created or mistags were
cleared, otherwise `noop`, and include
`reason=dashboard-refresh-timeout-prior-snapshot`. Do not mark the routine
`error` for a refresh-only timeout with a usable prior snapshot.

When the refresh succeeds, re-run `--stdout hygiene` and confirm
`orphan_live_count` dropped for the slugs you created.

### 6. Heartbeat

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "north-star-hygiene <ISO-ts> <ok|noop|error> created=<n> mistag_cleared=<m> orphan_live_left=<k>"
```

## Out of scope

- Promoting/moving cards or shipping product PRs
- Editing `active-programs` prose (program-driver / consolidate-brain)
- Inventing NS for unattributed cards
- Claude Artifact publishing (local HTML + brain `north-star-dashboard` is enough)

## Related

- Skill/tool: `last-stack-north-star-dashboard` · routine `north-star-rollup`
- Driving index: brain `active-programs`
- Orphan *completion* ledger (different problem): `fkanban-orphan-completion-checkpoints`
