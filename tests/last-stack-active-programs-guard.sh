#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

before="$tmp/before.md"
after="$tmp/after.md"
cat > "$before" <<'EOF_BEFORE'
## 1. Closed old program — ✅ CLOSED
**program-slug:** `[[old-program]]`
done

## 2. Active program
**program-slug:** `[[active-program]]`
next

## 3. Another active program
**program-slug:** `[[second-active-program]]`
next

## 4. North-star local-first app namespacing — ✅ CLOSED
**program-slug:** `[[north-star-local-first-app-namespacing]]`
reopened after historical closure
- local-first-app-namespacing-backfill is doing
- local-first-app-namespacing-dogfood is todo
EOF_BEFORE

cp "$before" "$after"
"$ROOT/bin/last-stack-active-programs-guard" check "$before" "$after"

board="$tmp/board.json"
proof="$tmp/proof-slugs.txt"
cat > "$board" <<'EOF_BOARD'
[
  {"slug":"done-card","column":"done"},
  {"slug":"live-card","column":"doing"},
  {"slug":"mixed-done-card","column":"done"},
  {"slug":"held-card","column":"backlog","block_status":"needs_human","block_reason":"host-side cutover"},
  {"slug":"retired-review-card","column":"review"},
  {"slug":"blocked-backlog-card","column":"backlog","block_status":"deferred"},
  {"slug":"table-done-card","column":"done"}
]
EOF_BOARD
cat > "$proof" <<'EOF_PROOF'
gone-card
EOF_PROOF
cat > "$after" <<'EOF_STALE'
## 1. Drained stale program
**program-slug:** `[[drained-program]]`
Next move still points at `done-card` and `gone-card`.
<!-- rollup:start | auto-maintained hourly by program-rollup — edit the prose above, NOT this block | updated 2026-07-10T00:00Z -->
**Status (auto):** 1/2 landed
cards: done-card, gone-card (gone)
<!-- rollup:end -->

## 2. Mixed active program
**program-slug:** `[[mixed-program]]`
Next move still includes `mixed-done-card`, but `live-card` is doing.
<!-- rollup:start | auto-maintained hourly by program-rollup — edit the prose above, NOT this block | updated 2026-07-10T00:00Z -->
**Status (auto):** 1/2 landed · in flight: live-card (doing)
cards: mixed-done-card, live-card
<!-- rollup:end -->

## 3. Held program
**program-slug:** `[[held-program]]`
Live next move says to pick up `held-card` once the host-side cutover is ready.
<!-- rollup:start | auto-maintained hourly by program-rollup — edit the prose above, NOT this block | updated 2026-07-10T00:00Z -->
**Status (auto):** 0/1 landed
cards: held-card
<!-- rollup:end -->

## Program: review-lane-program — Retired review lane program
**program-slug:** `[[review-lane-program]]`
Next move still names `retired-review-card`.

## Program: deferred-table-program — Deferred backlog table program
**program-slug:** `[[deferred-table-program]]`
Next move still says ship **blocked-backlog-card**.

| slug | column | notes |
|---|---|---|
| table-done-card | todo | stale table row |
EOF_STALE
cp "$after" "$tmp/stale-before"
"$ROOT/bin/last-stack-active-programs-guard" stale-report \
  --active "$after" \
  --board "$board" \
  --proof-slugs "$proof" > "$tmp/stale-report"
grep -q 'Drained stale program.*drained.*cue: Next move still points.*done-card (done).*gone-card (gone, proof).*suggested fix: archive done row or clear stale next move' "$tmp/stale-report"
grep -q 'Mixed active program.*mixed.*cue: Next move still includes.*mixed-done-card (done).*live-card (doing).*suggested fix: clear stale refs and advance prose to the live card' "$tmp/stale-report"
grep -q 'Held program.*held.*cue: Live next move says.*held-card (backlog, needs_human).*suggested fix: mark prose blocked/held or move next move to a ready card' "$tmp/stale-report"
grep -q 'Retired review lane program.*drained.*cue: Next move still names.*retired-review-card (review, retired).*suggested fix: archive done row or clear stale next move' "$tmp/stale-report"
grep -q 'Deferred backlog table program.*mixed.*cue: Next move still says.*table-done-card (done).*held: blocked-backlog-card (backlog, deferred).*suggested fix: archive done refs and mark held refs as blocked' "$tmp/stale-report"
cmp "$tmp/stale-before" "$after"

cat > "$after" <<'EOF_PROGRAM_STALE'
## Program: drained-program — Drained stale program
**program-slug:** `[[drained-program]]`
Next move still points at `done-card` and `gone-card`.
<!-- rollup:start | auto-maintained hourly by program-rollup — edit the prose above, NOT this block | updated 2026-07-10T00:00Z -->
**Status (auto):** 1/2 landed
cards: done-card, gone-card (gone)
<!-- rollup:end -->

## Program: mixed-program — Mixed active program
**program-slug:** `[[mixed-program]]`
Next move still includes `mixed-done-card`, but `live-card` is doing.
<!-- rollup:start | auto-maintained hourly by program-rollup — edit the prose above, NOT this block | updated 2026-07-10T00:00Z -->
**Status (auto):** 1/2 landed · in flight: live-card (doing)
cards: mixed-done-card, live-card
<!-- rollup:end -->
EOF_PROGRAM_STALE
cp "$after" "$tmp/program-stale-before"
"$ROOT/bin/last-stack-active-programs-guard" stale-report \
  --active "$after" \
  --board "$board" \
  --proof-slugs "$proof" > "$tmp/program-stale-report"
grep -q 'Drained stale program.*drained.*done-card (done).*gone-card (gone, proof)' "$tmp/program-stale-report"
grep -q 'Mixed active program.*mixed.*mixed-done-card (done).*live-card (doing)' "$tmp/program-stale-report"
cmp "$tmp/program-stale-before" "$after"

head -n 7 "$before" > "$after"
if "$ROOT/bin/last-stack-active-programs-guard" check "$before" "$after" >/dev/null 2>"$tmp/err"; then
  echo "expected truncated rewrite to fail" >&2
  exit 1
fi
grep -q 'program header count dropped' "$tmp/err"

sed '/second-active-program/d' "$before" > "$after"
if "$ROOT/bin/last-stack-active-programs-guard" check "$before" "$after" >/dev/null 2>"$tmp/err"; then
  echo "expected missing program slug to fail" >&2
  exit 1
fi
grep -q 'program slugs disappeared: second-active-program' "$tmp/err"

printf '%s' '<!-- rollup:end -->## 4. Embedded program header' >> "$after"
if "$ROOT/bin/last-stack-active-programs-guard" check "$before" "$after" >/dev/null 2>"$tmp/err"; then
  echo "expected embedded section header to fail" >&2
  exit 1
fi
grep -q 'embedded program header' "$tmp/err"

completed="$tmp/completed.md"
active_out="$tmp/active-out.md"
completed_out="$tmp/completed-out.md"
: > "$completed"
"$ROOT/bin/last-stack-active-programs-guard" archive-closed \
  --active "$before" \
  --completed "$completed" \
  --active-out "$active_out" \
  --completed-out "$completed_out"

if grep -q 'old-program' "$active_out"; then
  echo "closed program remained in active output" >&2
  exit 1
fi
grep -q 'active-program' "$active_out"
grep -q 'second-active-program' "$active_out"
grep -q 'north-star-local-first-app-namespacing' "$active_out"
grep -q 'Completed programs archive' "$completed_out"
grep -q '\[\[old-program\]\] - Closed old program' "$completed_out"
if grep -q 'north-star-local-first-app-namespacing' "$completed_out"; then
  echo "reopened active program was archived" >&2
  exit 1
fi
if "$ROOT/bin/last-stack-active-programs-guard" check "$before" "$active_out" >/dev/null 2>"$tmp/err"; then
  echo "expected intentional archive without completed output to fail" >&2
  exit 1
fi
grep -q 'program header count dropped' "$tmp/err"
"$ROOT/bin/last-stack-active-programs-guard" check \
  "$before" \
  "$active_out" \
  --completed-after "$completed_out"

"$ROOT/bin/last-stack-active-programs-guard" check "$before" "$before"

# --- Slug headers: preferred form (no ordinals) ---
slug_before="$tmp/slug-before.md"
slug_after="$tmp/slug-after.md"
cat > "$slug_before" <<'EOF_SLUG'
# Active programs

## Program: north-star-alpha — Alpha
**program-slug:** `[[north-star-alpha]]`
Next: ship A

## Program: north-star-beta
**program-slug:** `[[north-star-beta]]`
Next: ship B
EOF_SLUG

# Reorder sections (beta first) — must pass without renumbering
cat > "$slug_after" <<'EOF_REORDER'
# Active programs

## Program: north-star-beta
**program-slug:** `[[north-star-beta]]`
Next: ship B

## Program: north-star-alpha — Alpha
**program-slug:** `[[north-star-alpha]]`
Next: ship A
EOF_REORDER
"$ROOT/bin/last-stack-active-programs-guard" check "$slug_before" "$slug_after"

# Convert legacy ordinals → ## Program: with same slugs — must pass
cat > "$tmp/ordinal.md" <<'EOF_ORD'
## 1. Alpha
**program-slug:** `[[north-star-alpha]]`
a

## 2. Beta
**program-slug:** `[[north-star-beta]]`
b
EOF_ORD
cat > "$tmp/from-ordinal.md" <<'EOF_FROM'
## Program: north-star-alpha — Alpha
**program-slug:** `[[north-star-alpha]]`
a

## Program: north-star-beta — Beta
**program-slug:** `[[north-star-beta]]`
b
EOF_FROM
"$ROOT/bin/last-stack-active-programs-guard" check "$tmp/ordinal.md" "$tmp/from-ordinal.md"

# Wiki-header form also accepted
cat > "$tmp/wiki.md" <<'EOF_WIKI'
## [[north-star-alpha]] — Alpha
**program-slug:** `[[north-star-alpha]]`
a

## [[north-star-beta]]
**program-slug:** `[[north-star-beta]]`
b
EOF_WIKI
"$ROOT/bin/last-stack-active-programs-guard" check "$tmp/from-ordinal.md" "$tmp/wiki.md"

# archive-closed on ## Program: closed section
cat > "$tmp/slug-closed.md" <<'EOF_CLOSED'
## Program: old-program — ✅ CLOSED
**program-slug:** `[[old-program]]`
done

## Program: active-program
**program-slug:** `[[active-program]]`
next
EOF_CLOSED
: > "$tmp/completed2.md"
"$ROOT/bin/last-stack-active-programs-guard" archive-closed \
  --active "$tmp/slug-closed.md" \
  --completed "$tmp/completed2.md" \
  --active-out "$tmp/active2.md" \
  --completed-out "$tmp/completed2-out.md"
if grep -q 'old-program' "$tmp/active2.md"; then
  echo "slug-form closed program remained active" >&2
  exit 1
fi
grep -q 'active-program' "$tmp/active2.md"
grep -q '\[\[old-program\]\]' "$tmp/completed2-out.md"

# embedded ## Program: mid-line fails
cp "$slug_before" "$slug_after"
printf '%s' '<!-- x -->## Program: evil-slug' >> "$slug_after"
if "$ROOT/bin/last-stack-active-programs-guard" check "$slug_before" "$slug_after" >/dev/null 2>"$tmp/err"; then
  echo "expected embedded ## Program: header to fail" >&2
  exit 1
fi
grep -q 'embedded program header' "$tmp/err"

echo "ok"
