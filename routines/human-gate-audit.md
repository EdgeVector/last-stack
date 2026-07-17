---
name: human-gate-audit
cadence: daily
description: >
  Classify every intentional board hold (needs_human / design_first / deferred)
  into REAL_HUMAN, NOT_A_BLOCKER, or NEEDS_RECOMMENDATION. Clear false gates,
  file investigation cards that produce data + a Tom-ready recommendation, and
  write a short brain report for morning-sync. Triage-only — never ships product
  feature code.
---

## NO REVIEW COLUMN (Tom 2026-07-16 — won't-undo)

There is **no `review` column**. Columns: `backlog → todo → doing → done`.
`needs_human` holds live in **`backlog` only** (never todo/doing).

## Why this routine exists

Tom's question: *which "human blockers" are real, which are fake, and which
only need a recommendation after someone gathers data?*

`groom-board` + `kanban-grooming` do light re-audits and promotion. They do
**not** systematically:

1. Bucket every intentional hold,
2. Clear agent-fake gates,
3. File **investigation** cards whose job is "measure X → write RECOMMENDATION",
4. Publish a stable digest Tom can skim (`human-gate-audit-latest`).

This routine owns that loop.

## Three buckets (only these)

### A — `REAL_HUMAN`

Tom (or a vendor/pen) must act. Examples:

- Wet signature / board email / loan approvals / Form 8832
- Vendor account enablement (e.g. Backblaze Event Notifications)
- Secret material that has **no** LastSecrets path and only Tom can mint
- Explicit Tom freeze / "don't touch"
- Irreversible prod cutover with no standing authorization

**Action:** keep `needs_human` (or `deferred` if intentional park). Refresh
`block_reason` to **one crisp line**. Optionally Discord-page via
`last-stack-discord-needs-human` if stuck >48h and not already paged this week.
Do **not** file busywork investigation cards for pure pen/vendor work.

### B — `NOT_A_BLOCKER`

Agent-completable (possibly host-interactive, not "Tom product judgment"):

- Dirty install / LaunchAgent / host-track refresh (with standing machine permission
  or clear runbook — host ops, not pen)
- Missing DONE-WHEN / wrong kind / repo-header hygiene
- "Sandbox denied" when an interactive agent *can* do it
- Code already merged; only live apply remains and is agent-runnable
- Harness/script home in unversioned path → rehome PR is agent work

**Action:** `--block-status none`, move to `todo` if pickup-ready (`pr` +
repo + base, unblocked) else leave backlog if still dep-blocked. Append
`UNGATE <date>: <why>`. Never invent a new human gate.

### C — `NEEDS_RECOMMENDATION`

Work is blocked on **missing evidence**, not on Tom's pen. Examples:

- "Is it safe to delete dual-read?" → need inventory/key count
- "Is this secret provisioned?" → LastSecrets presence check
- "Is this feature already shipped?" → git/PR/probe check
- "Which repo owns this script?" → filesystem search + propose home

**Action (prefer in this order):**

1. **If cheap (minutes, read-only):** gather the data *in this run*, write
   `## RECOMMENDATION <date>` on the parent card with evidence + a **yes/no
   (or choose A/B)** ask for Tom. Clear `needs_human` only if the rec is
   "proceed agent-only"; else leave gate with reason
   `waiting Tom decision: see RECOMMENDATION <date>`.
2. **If not cheap:** file **one** investigation child card (Kind: `pr` or
   `validation`, pickup-ready) whose END STATE is:
   - durable evidence (path under `~/.last-stack/feature-proofs/` or brain note),
   - and a one-screen recommendation appended to the parent card.
   Parent stays `needs_human` with reason
   `waiting investigation: <child-slug>` until the child lands proof.

Do **not** leave Tom with "blocked" without either a crisp pen ask **or** an
active investigation card / in-run rec.

## Out of scope

- Shipping product feature code / open feature PRs (use pickup + kanban-agent)
- Deleting real cards because they are old
- Promoting `deferred` freezes Tom still wants (nano frozen, fold LastGit last, …)
- Putting secrets in brain/board/chat

## Setup

1. Situations: `situations list --json` (or workspace fallback). If blocked on
   shared mutation posture, still produce a **read-only classification report**
   and skip board writes.
2. Socket-backed board reads only. Busy-node → retry once, then skip writes and
   heartbeat `noop busy-node`.
3. Read `kanban-grooming` skill + human-gate section of this prompt.
4. Memory (if envelope provides path): last classifications to avoid re-filing
   duplicate investigation cards for the same parent.

## Procedure each run

### 1. Inventory holds

```bash
kanban list --column backlog --limit 200 --json > /tmp/hga-backlog.json
kanban list --column todo --limit 100 --json > /tmp/hga-todo.json
kanban list --column doing --limit 50 --json > /tmp/hga-doing.json
```

Select every card with `block_status` in
`needs_human | design_first | deferred` (any column — misplacement is a bug).

Also include cards whose body still has a top-level `NEEDS-HUMAN:` /
`BLOCKED: human` line even if `block_status` is empty (stale text).

### 2. Classify each hold (point-read body when reason is vague)

For each hold, assign **exactly one** bucket A/B/C with a one-line why.

Heuristics (prefer proof over labels):

| Signal | Bucket |
|--------|--------|
| pen / signature / email / loan / Form 8832 / vendor support | A |
| Tom freeze / deferred intentional park (`deferred`, nano frozen, …) | A (or keep deferred) |
| missing LastSecrets + only Tom can mint **and** you verified missing | A (or C if "check presence" is the unknown) |
| LastSecrets slug **exists** but card claims missing | B (ungate) |
| sandbox / LaunchAgent / dirty install / host-track apply | B if host-fixable; C if "is dirty intentional?" needs Tom once |
| dual-read / migration / "is it safe" without measurement | C |
| harness path / wrong repo / missing DONE-WHEN | B |
| design_first and deliverable is design Tom already approved | B → implement |
| design_first and Tom has not approved | A (or leave design_first) |

### 3. Act

- **B:** ungate + promote when pickup-ready; append UNGATE note.
- **C cheap:** measure, write RECOMMENDATION on parent, optional Discord if
  decision is the only remaining block.
- **C expensive:** file child investigation card if none exists:
  - slug: `hga-invest-<parent-slug-short>` or
    `investigate-<parent>-<yyyy-mm-dd>` (stable: reuse open child if present)
  - Kind: `pr` or `validation`, Repo/Base set, kanban-agent header when `pr`
  - Body must say: gather evidence, write RECOMMENDATION on parent, do not
    need Tom until recommendation exists
  - Dep: optional; parent should **not** block the child
- **A:** refresh `block_reason`; keep backlog.

Misplaced `needs_human` in todo/doing → demote to backlog first.

### 4. Publish digest (brain)

Upsert reference record `human-gate-audit-latest` (or append to existing):

```markdown
# Human-gate audit <ISO-date>

## Counts
- REAL_HUMAN: N
- NOT_A_BLOCKER cleared this run: N
- NEEDS_RECOMMENDATION (rec written): N
- NEEDS_RECOMMENDATION (investigation filed): N
- deferred left parked: N

## REAL_HUMAN (Tom / vendor / pen)
- `slug` — one-line ask

## Waiting on recommendation (Tom yes/no after evidence)
- `slug` — RECOMMENDATION one-liner or `waiting investigation: child`

## Cleared this run
- `slug` — why not a human gate

## Investigation cards filed
- `child` → parent `slug`
```

`morning-sync` and humans should read this first for "what do I actually need
to decide?"

### 5. Heartbeat

Last action:

```bash
"$HOME/.last-stack/bin/last-stack-brain-append-heartbeat" --line \
  "human-gate-audit <ISO-ts> <ok|noop|error> real=N cleared=N rec=N invest=N"
```

## Guardrails

- Never kill/restart primary `lastdbd` / forgejo.
- Never print secret values; LastSecrets **presence** only.
- Prefer `lastdb db inventory` / CoW scans for store-safety questions (read-only).
- Cap: at most **5** new investigation cards per run (file highest leverage first).
- Do not re-file an investigation if an open card already covers the parent.
- Deferred freezes Tom explicitly set stay deferred unless he unfroze them in brain.

## Definition of done for a run

- Every intentional hold classified once this run
- False gates cleared when evidence is clear
- Every C either has a RECOMMENDATION section or an open investigation child
- Brain `human-gate-audit-latest` updated
- Heartbeat written
