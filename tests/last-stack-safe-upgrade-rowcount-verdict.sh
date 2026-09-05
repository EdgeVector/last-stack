#!/usr/bin/env bash
# Unit tests for safe-upgrade rowcount_verdict (incident 2026-09-03).
# Pure helpers only — no node boot, no primary touch.
#
# Honor lastdb-a-test-that-cannot-fail-on-the-old-code-proves-nothing: a stub
# that treats candidate 0 as ok must NOT print RED. The live function must.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/rowcount-bar-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
chmod +x "$CHECKS" 2>/dev/null || true

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/rowcount-bar-checks.sh
. "$CHECKS"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Unfixed stub: the 2026-09-03 shape that discarded .total and treated 0 as ok.
# A test that this stub also "passes" proves nothing about the live function.
rowcount_verdict_unfixed() {
  local label="$1" cand="$2" base="$3"
  echo "rowcount $label ok: candidate=${cand} baseline=${base}"
  return 0
}

set +e
UNFIXED_OUT="$(rowcount_verdict_unfixed kanban-scan 0 11 2>&1)"
UNFIXED_RC=$?
set -e
[ "$UNFIXED_RC" -eq 0 ] || fail "unfixed stub must return 0 (that is the old bug)"
echo "$UNFIXED_OUT" | grep -q ' RED:' \
  && fail "unfixed stub must not print RED — otherwise this test cannot fail on the old code; out=$UNFIXED_OUT"

# Live function: baseline 11 / candidate 0 is RED, exit 1.
set +e
OUT="$(rowcount_verdict kanban-scan 0 11 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] || fail "0 vs 11 must exit 1; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'rowcount kanban-scan RED' \
  || fail "0 vs 11 must print RED; out=$OUT"

# Matching non-zero pair is ok.
set +e
OUT="$(rowcount_verdict kanban-scan 11 11 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "11 vs 11 must exit 0; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'rowcount kanban-scan ok' \
  || fail "11 vs 11 must print ok; out=$OUT"

# Unmeasurable candidate is SKIPPED, not RED.
set +e
OUT="$(rowcount_verdict kanban-scan -1 11 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "unmeasurable cand must exit 0; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'SKIPPED' || fail "expected SKIPPED; out=$OUT"

# Unmeasurable baseline is SKIPPED, not RED.
set +e
OUT="$(rowcount_verdict kanban-scan 11 -1 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "unmeasurable base must exit 0; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'SKIPPED' || fail "expected SKIPPED; out=$OUT"

# Partial drop is WARN, not RED.
set +e
OUT="$(rowcount_verdict kanban-scan 7 11 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "7 vs 11 must exit 0 (WARN); rc=$RC out=$OUT"
echo "$OUT" | grep -q ' WARN:' || fail "expected WARN; out=$OUT"

# Driver wires the module and still owns op_rows_scan.
grep -q 'rowcount-bar-checks.sh' "$DRIVER" \
  || fail "driver must source rowcount-bar-checks.sh"
grep -q 'rowcount_verdict' "$DRIVER" \
  || fail "driver must call rowcount_verdict"
grep -q 'op_rows_scan' "$DRIVER" \
  || fail "driver must still contain op_rows_scan"
# Inline function must be gone — the sourced helper is the producer.
awk '/^rowcount_verdict\(\)/{found=1} END{exit found?0:1}' "$DRIVER" \
  && fail "driver must not define rowcount_verdict inline after the extract"

echo "ok: rowcount_verdict unit tests"
