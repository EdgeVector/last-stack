---
name: owner-review-rotate
cadence: daily (08:45 local)
description: Daily ownership review — each owner triages its open papercuts against its charter + owned code
---

You are running the `owner-review-rotate` routine. Goal: make sure every papercut
reaches its owner, gets analyzed **in the context** of that area's code +
purpose, and moves forward — so we stop building towers of incorrect assumptions
from not reading the code.

**Shared contract:** fetch `brain get sop-routine-shared-contract --type sop` at
run start and honor it — heartbeat (LAST, always), primary-brain guardrail,
FILE-don't-ship card contract, dedupe-before-filing, scheduled-run shell
discipline, verify-vs-origin-main. If this prompt conflicts with it, the
contract wins.

Reach brain over the Unix socket `~/.lastdb/data/folddb.sock` (legacy `~/.folddb`
symlinks to it). Guardrails: per the shared contract, plus: do NOT touch any
live kanban worktree.

## Enumeration ban (won't-undo)

This routine must issue **zero whole-type brain enumerations**.

| Banned | Why | Use instead |
|---|---|---|
| `brain list --type agent --tag owner` | whole-type sample, not a charter census | Owner set from `ownership-map` (step 1 already reads it) |
| `brain list --tag papercut --status active` | wrong status vocabulary + list is a sample; measured empty while open papercuts exist | Charter "Open papercuts" section + `brain search` / `brain get` |
| `brain list --type papercut` as membership | list under-reports; not a ledger | Seeded `brain get` + search discovery only |

`brain list` remains a product honesty-sample elsewhere. **This consumer** does
not use it.

## Steps

1. Read the routing model: `brain get ownership-map` (type concept). **This is
   the owner set.** Parse every `owner-*` charter named in the map tables
   (repo-scoped owners, gap-fix owners, and any later table that lists a
   Charter column). Do **not** re-derive the owner set via `brain list`.

2. Iterate over each charter from step 1 **except** `owner-unassigned` (do that
   one LAST).
   **SKIP any charter marked `review: self-daily`** — as of 2026-08-08 that is
   `owner-lastdb-operations`, `owner-lastdb-cloud-sync`, and
   `owner-lastdb-data-lifecycle`. Each has its own daily routine that runs its
   own papercut pass; rotating them here triages the same records twice and
   fights their journal writes. Their cross-owner state lives in
   `owner-council-log`, not in this routine's log.
   The ownership-map "Domain-scoped daily owners" table is the skip list source
   of truth when it disagrees with an older note in this prompt.

3. For each owner charter:
   a. `brain get owner-<area>` — read Owns / Purpose / Invariants.
   b. Build that owner's open-papercut candidate set **without enumeration**:
      1. Prefer slugs listed in the charter's **"Open papercuts"** section
         (and any `papercut-…` tokens in recent review appendices).
      2. Discovery sample only: `brain search "owner:<area>" --type papercut`
         and/or `brain search "papercut owner <area>" --type papercut`
         (`--limit` small). Treat search as incomplete.
      3. For every candidate slug, authoritative read:
         `brain get <slug>` (or `--type papercut` when known). Keep only
         records that are still open/active for this owner (tag
         `owner:<area>`, or still listed on the charter). Drop archived /
         closed / wrong-owner hits.
      4. Never filter with `--status active` on papercuts — live papercut
         status vocabulary is typically `open` / `archived`, not kanban-style
         `active`. The old `--status active` path measured empty while open
         papercuts existed.
   c. READ THE ACTUAL OWNED CODE for the paths in "Owns" before judging — this
      is the whole point; do not diagnose from the papercut text alone.
   d. For each open papercut, decide EXACTLY ONE outcome and record it:
      - FIX: enrich/open the kanban fix card with a grounded diagnosis +
        `## END STATE` (owner has the North Star, so `--north-star` is natural).
        Cross-link card↔papercut.
      - CLOSE: if resolved/obsolete, verify against code, then set the papercut
        `status: archived` with a one-line rationale appended.
      - ESCALATE: swap the `owner:` tag to the correct owner + append a
        one-line note.
   e. Bump the charter's `Last reviewed` line to today's date (`brain append`
      or a targeted edit — do NOT full-replace the body).

4. LAST: run `owner-unassigned` — assign every `owner:unassigned` / untagged
   open papercut to a real owner per the routing table; if one fits no owner,
   file a card to draft a new charter. Discover unassigned candidates via
   `brain search "owner:unassigned" --type papercut` and
   `brain search "unassigned papercut" --type papercut` plus any unassigned
   seeds already known on the ownership-map / prior log — **not** via
   `brain list`. After this pass, ZERO open papercuts should remain unassigned
   among the candidates you actually reached (note any search incompleteness
   in the log).

5. Append a one-line summary per owner (reviewed count / fixed / closed /
   escalated / still-open) to a brain reference record `owner-review-rotate-log`
   (create it if missing, type reference, tag owner-review).

Keep it bounded: if an owner has many papercuts, cover the top few by impact and
note the remainder in the log. Never rerun-past a real signal; a
stale/unreviewed queue is itself the bug to surface.

**Time-box (hard):** this routine's exec budget is finite. Note the wall-clock
time at run start. After roughly 20 minutes of elapsed time, stop opening new
owners — finish (or abandon mid-write-safely) whatever single papercut/charter
edit is in flight, then jump straight to step 5 (log which owners/papercuts
were NOT reached this pass, so tomorrow's run picks up there) and the
heartbeat. Do not let step 3's per-owner loop or step 4's unassigned sweep run
past this checkpoint even if papercuts remain — an incomplete-but-heartbeated
`ok`/`noop` run beats a hard timeout that can abort mid brain-write. The
backlog is reviewed incrementally across days by design; finishing every owner
in one run is not required.

## Heartbeat (LAST, always — contract §1)
`owner-review-rotate <ISO-ts> <ok|noop|error> <one-line outcome>`
