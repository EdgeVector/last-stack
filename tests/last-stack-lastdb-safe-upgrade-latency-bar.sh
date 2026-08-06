#!/usr/bin/env bash
# Unit tests for safe-upgrade correlated latency bar (2026-08-05).
# Pure helpers only — no node boot, no primary touch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
chmod +x "$CHECKS" 2>/dev/null || true

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh
. "$CHECKS"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- pure helpers ------------------------------------------------------------
lat_pair_measurable 58 24 || fail "58/24 should be measurable"
lat_pair_measurable -1 24 && fail "-1 cand must not be measurable"
lat_pair_measurable 58 -1 && fail "-1 base must not be measurable"
lat_pair_measurable "" 24 && fail "empty cand must not be measurable"
lat_pair_measurable 0 24 && fail "zero cand must not be measurable"

r="$(lat_ratio 58 24)"
awk -v r="$r" 'BEGIN{exit !(r+0 > 2.4 && r+0 < 2.42)}' \
  || fail "lat_ratio 58/24 expected ~2.4167 got $r"

geo="$(printf '2.416667 1.733696 1.599862\n' | lat_geo_mean 3)" \
  || fail "geo_mean of three ratios should succeed"
# (2.416667 * 1.733696 * 1.599862)^(1/3) ≈ 1.885
awk -v g="$geo" 'BEGIN{exit !(g+0 > 1.85 && g+0 < 1.92)}' \
  || fail "geo_mean of Aug-5 ratios expected ~1.88 got $geo"

printf '1.0\n' | lat_geo_mean 2 >/dev/null \
  && fail "geo_mean with min_n=2 and one value must fail"

# --- Aug 5 canary numbers: MUST RED (the whole point of this bar) -----------
# point 58/24=2.42x  scan 319/184=1.73x  write 4646/2904=1.60x
# All under per-op 3x, all over corr 1.4x, geo mean ~1.88 > 1.5
unset LASTDB_PROBE_LAT_CORR_SKIP
export LASTDB_PROBE_LAT_CORR_RATIO=1.4
export LASTDB_PROBE_LAT_GEO_MEAN_MAX=1.5
export LASTDB_PROBE_LAT_CORR_MIN_OPS=2

set +e
OUT="$(lat_correlated_within_bar 58 24 319 184 4646 2904 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "Aug-5 canary numbers must RED; out=$OUT"
echo "$OUT" | grep -q 'RED:' || fail "expected RED: line; out=$OUT"
# Either term may fire; both are correct. Prefer seeing at least one.
echo "$OUT" | grep -Eq 'all [0-9]+ measurable ops regress|geometric mean' \
  || fail "expected all-ops or geo-mean reason; out=$OUT"

# --- healthy / slightly better: GREEN ----------------------------------------
set +e
OUT="$(lat_correlated_within_bar 53 53 287 288 2946 3237 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "healthy pair should GREEN; out=$OUT"
echo "$OUT" | grep -q 'GREEN:' || fail "expected GREEN: line; out=$OUT"

# --- mild uniform noise under thresholds: GREEN ------------------------------
# ~1.2x all around — below 1.4 all-ops and geo mean ~1.2 < 1.5
set +e
OUT="$(lat_correlated_within_bar 30 24 220 184 3500 2904 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "mild ~1.2x should GREEN; out=$OUT"

# --- all-ops tight regress without geo mean necessarily over: RED ------------
# 1.45 each → all >= 1.4; geo mean 1.45 may or may not exceed 1.5 (does not)
set +e
OUT="$(lat_correlated_within_bar 35 24 267 184 4205 2900 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "uniform 1.45x all-ops must RED via corr ratio; out=$OUT"
echo "$OUT" | grep -q 'all .* measurable ops regress' \
  || fail "expected all-ops tight-regress reason; out=$OUT"

# --- one op huge, others flat: per-op would catch; correlated may not all-ops
# point 2.5x, scan 1.0x, write 1.0x → not all regress; geo mean ~1.36 < 1.5
set +e
OUT="$(lat_correlated_within_bar 60 24 200 200 3000 3000 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "single-op moderate without aggregate should GREEN corr; out=$OUT"

# --- geo-mean only (mixed, not all at 1.4) ------------------------------------
# 2.5, 1.4, 1.3 → geo ≈ 1.66 > 1.5; not all >= 1.4 (1.3 is under)
set +e
OUT="$(lat_correlated_within_bar 60 24 280 200 3900 3000 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "geo-mean-only case must RED; out=$OUT"
echo "$OUT" | grep -q 'geometric mean' \
  || fail "expected geo-mean reason; out=$OUT"

# --- insufficient measurable pairs: no aggregate applied ---------------------
set +e
OUT="$(lat_correlated_within_bar 58 24 -1 -1 -1 -1 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "single measurable pair should skip aggregate; out=$OUT"
echo "$OUT" | grep -q 'only 1 measurable' \
  || fail "expected only-1-measurable message; out=$OUT"

# --- skip override -----------------------------------------------------------
export LASTDB_PROBE_LAT_CORR_SKIP=1
set +e
OUT="$(lat_correlated_within_bar 58 24 319 184 4646 2904 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "CORR_SKIP=1 must GREEN; out=$OUT"
echo "$OUT" | grep -q 'SKIPPED' || fail "expected SKIPPED; out=$OUT"
unset LASTDB_PROBE_LAT_CORR_SKIP

# --- driver wires the module -------------------------------------------------
grep -q 'latency-bar-checks.sh' "$DRIVER" \
  || fail "driver must source latency-bar-checks.sh"
grep -q 'lat_correlated_within_bar' "$DRIVER" \
  || fail "driver must call lat_correlated_within_bar"
grep -q 'LASTDB_PROBE_LAT_CORR_RATIO' "$DRIVER" \
  || fail "driver must expose LASTDB_PROBE_LAT_CORR_RATIO"
grep -q 'LASTDB_PROBE_LAT_GEO_MEAN_MAX' "$DRIVER" \
  || fail "driver must expose LASTDB_PROBE_LAT_GEO_MEAN_MAX"

# --- skill docs mention the aggregate term -----------------------------------
grep -q 'LASTDB_PROBE_LAT_CORR_RATIO\|correlated' "$SKILL_MD" \
  || fail "SKILL.md must document the correlated latency term"

echo "OK: correlated latency bar (Aug-5 numbers RED; healthy GREEN)"
