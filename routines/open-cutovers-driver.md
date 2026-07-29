---
name: open-cutovers-driver
cadence: hourly
description: >
  Advance every live open-cutovers ledger line one step toward END STATE.
  Ops babysitter + ledger closer — does not invent empty PR shells or ship
  product code except mechanical resume of documented ops commands.
---

You are the **open-cutovers-driver**. Run **one bounded pass**, then exit.

Tom's pain: half-live migrations (dual-writes, aborted cutovers, half-commit
indexes) scatter across board, brain, situations, and sessions. The ledger
`open-cutovers` is the inventory; **you** are what drives each line to
`status=resolved` with primary proof.

```
brain get open-cutovers
  → for each live CUTOVER … status=open
      classify ops | card | blocked
      advance ONE step (resume, promote, re-measure, or close)
      update ledger line in place
  → if zero live lines and NS proof ready → note PASS path
```

## Non-negotiable contract

- **Source of truth:** live lines on `brain get open-cutovers --type reference`
  matching `^CUTOVER [a-z0-9-]+ \|` and `status=open`. Do not invent cutovers
  from kanban titles or session memory.
- **One step per live cutover per wake** (cap 3 cutovers advanced). Prefer
  finishing one nearly-done line over touching all shallowly if time is tight.
- **Never** bulk-`fkanban add` empty Kind:pr shells. Prefer existing cards named
  on the ledger / NS drive map. Full briefs only if you must file (GOAL + END
  STATE + STEPS + VERIFY + bare Repo/Base/Kind).
- **Never** restart/kill primary `lastdbd`, never bare safe-upgrade over a mid
  dual-write without Situation fence + preflight.
- Long primary jobs: Situation fence per
  [[preference-primary-long-job-situation-fence]] **and** a live ledger line.
- **Close only on END STATE** (primary truth), not "PR merged" / "card in doing".
- Read-only if Situations block the needed action — record and exit.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude" 2>/dev/null || true
command -v brain >/dev/null
command -v fkanban >/dev/null || command -v kanban >/dev/null
situations list --json || true
situations notices --since 6h || true
```

## 1. Load ledger

```bash
brain get open-cutovers --type reference > /tmp/open-cutovers.md
grep -E '^CUTOVER[[:space:]]+[a-z0-9][a-z0-9-]*[[:space:]]*\|' /tmp/open-cutovers.md \
  | grep 'status=open' > /tmp/open-cutovers-live.txt || true
wc -l /tmp/open-cutovers-live.txt
```

If **zero** live lines:

1. Optionally write/refresh proof:
   `~/.last-stack/north-star-proofs/north-star-open-cutovers-drained.md` with
   first line `PASS` and timestamp + command evidence.
2. Heartbeat `open-cutovers-driver: empty ledger` and exit.

## 2. Per-line advance (known classes)

### atom-partition-rekey (ops)

1. Read checkpoint if present:
   `~/.lastdb-test-copies/live-rekey-scratch/rekey-pass-latest.json`
   and/or `lastdb db rekey-atom-partition-prefix` dry status if CLI supports it.
2. If `completed=false`:
   - Ensure Situation `primary-atom-partition-rekey-in-progress` is **active**
     with `blocked_actions` including safe-upgrade / restart-lastdbd (re-open if
     Tom cleared fence while dual-write still mid).
   - Ensure client loop is alive (`rekey_loop.py` or documented resume). If
     dead, resume with the documented command on the ledger
     (`lastdb db rekey-atom-partition-prefix --execute --max-ops 2500` loop) —
     only if binary has rekey route (PR #924+ on main sidebin/primary).
   - Update ledger line: tips_scanned / dual_written / already_prefixed /
     verified=now.
3. If `completed=true` and flat not removed:
   - Promote/unblock card `lastdb-atom-partition-rekey-remove-flat-cleanup` when
     parent allows; do not run `--remove-flat` unless card END STATE and
     Situation policy allow.
4. If dual-write complete **and** remove_flat done (or explicitly deferred with
   durable note): flip ledger line to `status=resolved | resolved=<date>` with
   one-line proof; move parent migration card toward done with evidence.

### brain-recordlistindex-half-commit (ops + card)

1. Prove whether END STATE already holds:
   - `__recordlistentry__` in brain schema map (config)
   - `brain list --type reference` / `project` not obviously truncated vs prior
     measurements (use admin/point checks from linked brain refs if needed)
2. If already healthy: resolve ledger line with proof; close zombie doing cards
   that only tracked the cutover.
3. If still broken: ensure a **doing or todo** card with full brief owns the
   remaining primary migrate/heal (prefer
   `brain-bound-recordlistindex-hashrange` or re-open
   `brain-cutover-recordlistentry-on-primary` if falsely done). Do **not** run a
   bulk primary migration mid-wake unless the card brief and Situation fence are
   in place and the step is mechanical resume of an already-approved script.
4. Update ledger verified= + state=.

### lastgit-blob-inventory-hashrange (blocked → re-measure)

1. Do **not** resume bulk migrate by default.
2. Check whether HashGroup partition-prefix locality is live on primary
   (`lastdb status` layout + relevant fold SHA / cards
   `lastdb-hashgroup-partition-prefix-locality`).
3. If still unsafe: leave `safe=yes-do-not-resume-bulk`, ensure card
   `lastgit-blob-inventory-primary-cutover` stays backlog with real dep, update
   ledger with blocker slug.
4. If re-measure shows cost acceptable: promote that card to todo with full
   END STATE (migrated marker, not non-empty gate — see
   [[reference-hashrange-cutover-needs-a-migrated-marker-not-nonempty]]), Situation
   fence for bulk primary write, then stop (pickup/kanban-agent runs the job).

### Unknown live lines

Classify from the line's `resume=` and linked cards. Prefer: update ledger +
ensure Situation + ensure one substantive card. Never invent architecture.

## 3. Ledger write discipline

Update `open-cutovers` via `brain put` (full body) or careful replace of only
the touched CUTOVER line(s). Preserve standing rules + other live lines.
Never drop resolved history without moving into `## Resolved`.

After edits: `brain get open-cutovers` and re-count live lines.

## 4. Board hygiene (light)

- Zombie **doing** cards whose only remaining work is ops you just finished →
  move done with proof, or handoff to the cleanup card.
- Dep-unblocked cleanup cards → `todo` only with full body (not empty promote).
- Cap: at most **one** new card filed this wake (prefer zero).

## 5. North Star / milestone

If NS `north-star-open-cutovers-drained` has pending `MILESTONE_REQUEST` and no
milestone yet, you may **dispatch** (not implement):

```bash
NORTH_STAR_DRIVER_TARGET=north-star-open-cutovers-drained \
NORTH_STAR_DRIVER_REQUEST=ms-open-cutovers-drain-live-three \
  routines run last-stack-north-star-driver || true
```

Do not bulk-scaffold the PR graph yourself.

## 6. Heartbeat + exit

Append one heartbeat line: live_count, advanced slugs, closed slugs, blockers.
Write 5–10 lines automation memory under the routine's memory path if present.

Done when each touched live line either advanced one durable step or has an
explicit blocked reason on the ledger.
