#!/usr/bin/env bash
# Unit tests for safe-upgrade candidate-class gates (incident 2026-08-01).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/candidate-class-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/candidate-class-checks.sh
. "$CHECKS"

# --- pure helpers ------------------------------------------------------------
candidate_path_is_debug \
  "/Users/ci-runner/.fkanban/worktrees/fold-x/target/debug/lastdbd" \
  || { echo "FAIL: should flag target/debug path" >&2; exit 1; }
candidate_path_is_debug \
  "/Users/ci-runner/.lastdb/bin-with-upload-cap/lastdbd" \
  && { echo "FAIL: sidebin path must not be debug" >&2; exit 1; }
candidate_path_is_debug \
  "/tmp/target/release/lastdbd" \
  && { echo "FAIL: target/release must not be debug" >&2; exit 1; }

candidate_version_is_dirty "0.23.2-258-ge212b221a-dirty" \
  || { echo "FAIL: -dirty version should flag" >&2; exit 1; }
candidate_version_is_dirty "0.23.2-235-g4f5476498" \
  && { echo "FAIL: clean version must not flag dirty" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cand-class-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# small "release" and large "debug" stand-ins
printf 'small' >"$TMP/release-bin"
# ~3x larger
dd if=/dev/zero of="$TMP/debug-bin" bs=1 count=18 2>/dev/null || \
  head -c 18 /dev/zero >"$TMP/debug-bin"
candidate_size_ratio_over "$TMP/debug-bin" "$TMP/release-bin" 1.5 \
  || { echo "FAIL: 18 vs 5 bytes should exceed 1.5x" >&2; exit 1; }
candidate_size_ratio_over "$TMP/release-bin" "$TMP/debug-bin" 1.5 \
  && { echo "FAIL: smaller cand must not exceed ratio" >&2; exit 1; }

# assert_candidate_class_ok: debug+dirty RED
mkdir -p "$TMP/tree/target/debug"
cp "$TMP/debug-bin" "$TMP/tree/target/debug/lastdbd"
chmod +x "$TMP/tree/target/debug/lastdbd"
OUT=""
set +e
OUT="$(assert_candidate_class_ok "$TMP/tree/target/debug/lastdbd" "0.1.0-gabc-dirty" "$TMP/release-bin" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: expected RED for debug+dirty; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'RED:' || { echo "FAIL: expected RED: lines; out=$OUT" >&2; exit 1; }

# clean release path + clean version + similar size → OK
cp "$TMP/release-bin" "$TMP/ok-lastdbd"
chmod +x "$TMP/ok-lastdbd"
set +e
OUT="$(assert_candidate_class_ok "$TMP/ok-lastdbd" "0.23.2-235-g4f5476498" "$TMP/release-bin" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: clean candidate should pass; out=$OUT" >&2; exit 1; }

# overrides allow dirty/debug
export LASTDB_ALLOW_DEBUG_CANDIDATE=1
export LASTDB_ALLOW_DIRTY_CANDIDATE=1
export LASTDB_ALLOW_LARGE_CANDIDATE=1
set +e
OUT="$(assert_candidate_class_ok "$TMP/tree/target/debug/lastdbd" "0.1.0-gabc-dirty" "$TMP/release-bin" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: overrides should allow; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'WARN:' || { echo "FAIL: overrides should WARN; out=$OUT" >&2; exit 1; }
unset LASTDB_ALLOW_DEBUG_CANDIDATE LASTDB_ALLOW_DIRTY_CANDIDATE LASTDB_ALLOW_LARGE_CANDIDATE

# --- driver wires the gates --------------------------------------------------
grep -q 'candidate-class-checks.sh' "$DRIVER" || {
  echo "FAIL: driver must source candidate-class-checks.sh" >&2
  exit 1
}
grep -q 'assert_candidate_class_ok' "$DRIVER" || {
  echo "FAIL: driver must call assert_candidate_class_ok" >&2
  exit 1
}
grep -q 'LAT_FLOOR_MS=.*250\|LASTDB_PROBE_LAT_FLOOR_MS:-250' "$DRIVER" || {
  echo "FAIL: driver default LAT_FLOOR_MS should be 250 (incident 2026-08-01)" >&2
  exit 1
}
grep -q 'live_scan_ms\|LIVE_LAT_SCAN_MS' "$DRIVER" || {
  echo "FAIL: driver must measure live scan latency" >&2
  exit 1
}
grep -q 'live kanban-scan\|live scan' "$DRIVER" || {
  echo "FAIL: driver must time live kanban list" >&2
  exit 1
}

# --- skill docs --------------------------------------------------------------
grep -qi 'debug\|dirty\|candidate.class\|candidate-class' "$SKILL_MD" || {
  echo "FAIL: SKILL.md must document candidate-class / no-debug gates" >&2
  exit 1
}
grep -qi 'live.*scan\|kanban list' "$SKILL_MD" || {
  echo "FAIL: SKILL.md must document live scan post-check" >&2
  exit 1
}
grep -q '2026-08-01\|incident 2026-08-01' "$SKILL_MD" || {
  echo "FAIL: SKILL.md should cite 2026-08-01 incident" >&2
  exit 1
}

echo "OK: lastdb-safe-upgrade candidate-class + live-scan gates"
