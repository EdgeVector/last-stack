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
# Over-floor: 500/200=2.5, 280/200=1.4, 3900/3000=1.3 → geo ≈ 1.66 > 1.5
set +e
OUT="$(lat_correlated_within_bar 500 200 280 200 3900 3000 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "geo-mean-only case must RED; out=$OUT"
echo "$OUT" | grep -q 'geometric mean' \
  || fail "expected geo-mean reason; out=$OUT"

# --- insufficient measurable pairs: no aggregate applied ---------------------
# 58/24 both under floor (noise); only 319/184 remains → 1 pair.
set +e
OUT="$(lat_correlated_within_bar 58 24 319 184 -1 -1 2>&1)"
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
grep -q 'lat_apply_like_to_like_bars' "$DRIVER" \
  || fail "driver must call lat_apply_like_to_like_bars"
grep -q 'lat_cold_point_ms\|cold point' "$DRIVER" \
  || fail "driver must record named cold point times"
grep -q 'lat_hot_point_ms\|hot point' "$DRIVER" \
  || fail "driver must record named hot point times"
grep -q 'mixed thermal' "$DRIVER" "$CHECKS" \
  || fail "helpers must name mixed thermal skip"

# --- skill docs mention the aggregate term -----------------------------------
grep -q 'LASTDB_PROBE_LAT_CORR_RATIO\|correlated' "$SKILL_MD" \
  || fail "SKILL.md must document the correlated latency term"
grep -qi 'cold' "$SKILL_MD" && grep -qi 'hot' "$SKILL_MD" \
  || fail "SKILL.md must name cold and hot as distinct probe outputs"

# --- (a) mixed pair 354 cold vs 50 hot must not RED --------------------------
export LASTDB_PROBE_LAT_FLOOR_MS=250
export LASTDB_PROBE_LAT_RATIO=3
set +e
OUT="$(lat_op_like_to_like_within_bar "point-read" 354 50 cold hot 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "mixed 354-cold/50-hot must not RED; out=$OUT"
echo "$OUT" | grep -q 'mixed thermal skipped' \
  || fail "expected mixed thermal skip; out=$OUT"

# --- (b) hot 437/387 + 2463/2636 + non-7x hot point GREEN --------------------
set +e
OUT="$(lat_apply_like_to_like_bars \
  354 354 -1 -1 \
  300 250 437 387 2463 2636 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "hot like-to-like non-7x must GREEN; out=$OUT"
echo "$OUT" | grep -q 'GREEN' || fail "expected GREEN in like-to-like; out=$OUT"

# --- (c) Aug-5 remaining over-floor pairs still RED --------------------------
# 58/24 both under floor (noise); 319/184 and 4646/2904 remain.
set +e
OUT="$(lat_correlated_within_bar 58 24 319 184 4646 2904 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "Aug-5 over-floor pairs must still RED; out=$OUT"

# --- (d) cold-vs-cold 5–20× first-query still RED ----------------------------
set +e
OUT="$(lat_op_like_to_like_within_bar "cold point-read" 5000 250 cold cold 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "cold-vs-cold 20x must RED; out=$OUT"
echo "$OUT" | grep -q 'RED:' || fail "expected cold RED; out=$OUT"

echo "OK: correlated latency bar (Aug-5 numbers RED; healthy GREEN; cold/hot like-to-like)"
