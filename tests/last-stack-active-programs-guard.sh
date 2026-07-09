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
- local-first-app-namespacing-dogfood is review
EOF_BEFORE

cp "$before" "$after"
"$ROOT/bin/last-stack-active-programs-guard" check "$before" "$after"

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

echo "ok"
