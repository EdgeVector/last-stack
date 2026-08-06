#!/usr/bin/env bash
# Pure latency-bar aggregate checks for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# Per-op 3× (LAT_RATIO) still lives in the driver — it catches a single
# catastrophic op (0.23.1 scan 5–20×). This module closes the other shape:
# a BROAD, moderate regression that leaves every op under 3× but still worse
# on the whole (2026-08-05 canary: point 2.42× / scan 1.73× / write 1.60×
# all GREEN under per-op 3×, then live multi-writer writes ~10s).
# Brain: papercut-safe-upgrade-latency-bar-blind-to-correlated-regression.
#
# Two complementary terms (either REDs):
#   1. ALL measurable ops regress at >= LAT_CORR_RATIO (default 1.4)
#   2. Geometric mean of cand/base ratios across measurable ops
#      exceeds LAT_GEO_MEAN_MAX (default 1.5)
#
# A pair is measurable only when both cand and base are positive integers
# (not -1 / empty / 0). Need at least LAT_CORR_MIN_OPS (default 2) pairs;
# a single measured op is already covered by the per-op 3× bar.
#
# Env (read at call time; driver may set defaults first):
#   LASTDB_PROBE_LAT_CORR_RATIO      default 1.4
#   LASTDB_PROBE_LAT_GEO_MEAN_MAX    default 1.5
#   LASTDB_PROBE_LAT_CORR_MIN_OPS    default 2
#   LASTDB_PROBE_LAT_CORR_SKIP       1 = no-op GREEN (Tom clearance only)
#
# bash 3.2 compatible (macOS /bin/bash) — no namerefs, no nested functions.

# rc 0 = measurable positive pair; rc 1 = not
lat_pair_measurable() {
  local cand="${1:-}" base="${2:-}"
  [ -n "$cand" ] && [ "$cand" != "-1" ] || return 1
  [ -n "$base" ] && [ "$base" != "-1" ] || return 1
  [ "$cand" -gt 0 ] 2>/dev/null || return 1
  [ "$base" -gt 0 ] 2>/dev/null || return 1
  return 0
}

# Print cand/base as a float ratio, or empty if not measurable.
lat_ratio() {
  local cand="$1" base="$2"
  lat_pair_measurable "$cand" "$base" || return 0
  awk -v c="$cand" -v b="$base" 'BEGIN{
    if (b <= 0) exit 0
    printf "%.6f", c / b
  }'
}

# Geometric mean of whitespace-separated positive floats on stdin.
# Prints nothing (and rc 1) when fewer than $1 values.
lat_geo_mean() {
  local min_n="${1:-1}"
  awk -v min_n="$min_n" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i + 0 > 0) { n++; logsum += log($i + 0) }
      }
    }
    END {
      if (n < min_n) exit 1
      printf "%.6f", exp(logsum / n)
    }
  '
}

# Append one measurable op into the ratio/detail accumulators via globals
# set by lat_correlated_within_bar. bash-3.2-safe (no namerefs).
# Args: label cand_ms base_ms
_lat_corr_append_pair() {
  local label="$1" cand="$2" base="$3" ratio
  lat_pair_measurable "$cand" "$base" || return 0
  ratio="$(lat_ratio "$cand" "$base")"
  [ -n "$ratio" ] || return 0
  _LAT_CORR_RATIOS="${_LAT_CORR_RATIOS:+$_LAT_CORR_RATIOS }$ratio"
  if [ -n "$_LAT_CORR_DETAILS" ]; then
    _LAT_CORR_DETAILS="${_LAT_CORR_DETAILS}; ${label}=${cand}ms/${base}ms (${ratio}x)"
  else
    _LAT_CORR_DETAILS="${label}=${cand}ms/${base}ms (${ratio}x)"
  fi
  _LAT_CORR_N_MEAS=$((_LAT_CORR_N_MEAS + 1))
  if awk -v r="$ratio" -v thr="$_LAT_CORR_RATIO" 'BEGIN{exit !(r + 0 >= thr + 0)}'; then
    _LAT_CORR_N_REGRESS=$((_LAT_CORR_N_REGRESS + 1))
  fi
}

# Aggregate correlated-regression bar over point/scan/write.
# Args: c_point b_point c_scan b_scan c_write b_write
# Prints human-readable findings to stdout (one per line).
# rc 0 = within bar; rc 1 = RED.
lat_correlated_within_bar() {
  local c_point="$1" b_point="$2"
  local c_scan="$3" b_scan="$4"
  local c_write="$5" b_write="$6"

  if [ "${LASTDB_PROBE_LAT_CORR_SKIP:-0}" = "1" ]; then
    printf 'latency correlated SKIPPED (LASTDB_PROBE_LAT_CORR_SKIP=1)\n'
    return 0
  fi

  _LAT_CORR_RATIO="${LASTDB_PROBE_LAT_CORR_RATIO:-1.4}"
  local geo_max min_ops
  geo_max="${LASTDB_PROBE_LAT_GEO_MEAN_MAX:-1.5}"
  min_ops="${LASTDB_PROBE_LAT_CORR_MIN_OPS:-2}"

  _LAT_CORR_RATIOS=""
  _LAT_CORR_DETAILS=""
  _LAT_CORR_N_MEAS=0
  _LAT_CORR_N_REGRESS=0

  _lat_corr_append_pair "point" "$c_point" "$b_point"
  _lat_corr_append_pair "scan" "$c_scan" "$b_scan"
  _lat_corr_append_pair "write" "$c_write" "$b_write"

  if [ "$_LAT_CORR_N_MEAS" -lt "$min_ops" ]; then
    printf 'latency correlated: only %s measurable pair(s) (need %s) — aggregate bar not applied\n' \
      "$_LAT_CORR_N_MEAS" "$min_ops"
    return 0
  fi

  local geo red=0
  geo="$(printf '%s\n' "$_LAT_CORR_RATIOS" | lat_geo_mean "$min_ops" || true)"

  # Term 1: every measurable op regressed at/above the tight ratio.
  if [ "$_LAT_CORR_N_REGRESS" -eq "$_LAT_CORR_N_MEAS" ] && [ "$_LAT_CORR_N_MEAS" -ge "$min_ops" ]; then
    printf 'latency correlated RED: all %s measurable ops regress at >=%sx (%s)\n' \
      "$_LAT_CORR_N_MEAS" "$_LAT_CORR_RATIO" "$_LAT_CORR_DETAILS"
    red=1
  fi

  # Term 2: geometric mean of ratios exceeds the aggregate ceiling.
  if [ -n "$geo" ] && awk -v g="$geo" -v m="$geo_max" 'BEGIN{exit !(g + 0 > m + 0)}'; then
    printf 'latency correlated RED: geometric mean of ratios %sx > %sx ceiling (%s)\n' \
      "$geo" "$geo_max" "$_LAT_CORR_DETAILS"
    red=1
  fi

  if [ "$red" -ne 0 ]; then
    return 1
  fi

  if [ -n "$geo" ]; then
    printf 'latency correlated GREEN: geo_mean=%sx (max %sx) all_ops_tight_regress=%s/%s (thr %sx) (%s)\n' \
      "$geo" "$geo_max" "$_LAT_CORR_N_REGRESS" "$_LAT_CORR_N_MEAS" "$_LAT_CORR_RATIO" "$_LAT_CORR_DETAILS"
  else
    printf 'latency correlated GREEN: no geo_mean; all_ops_tight_regress=%s/%s (thr %sx) (%s)\n' \
      "$_LAT_CORR_N_REGRESS" "$_LAT_CORR_N_MEAS" "$_LAT_CORR_RATIO" "$_LAT_CORR_DETAILS"
  fi
  return 0
}
