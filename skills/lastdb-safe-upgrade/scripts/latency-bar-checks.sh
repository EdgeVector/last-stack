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
#   LASTDB_PROBE_LAT_FLOOR_MS        default 250 (or LAT_FLOOR_MS)
#   LASTDB_PROBE_LAT_RATIO           default 3   (or LAT_RATIO)
#   LASTDB_PROBE_LAT_ABS_MAX_MS      default 20000 (or LAT_ABS_MAX_MS)
#
# Thermal: cold = first query after identity-ready; hot = after settle +
# discarded warmup. Like-to-like only. A mixed pair (cold vs hot) must not RED.
# Pairs where both times are under the floor are noise, not a ratio.
# Geo-mean uses the HOT triple only (driver passes hot times in).
#
# bash 3.2 compatible (macOS /bin/bash) — no namerefs, no nested functions.

lat_floor_ms() {
  printf '%s\n' "${LASTDB_PROBE_LAT_FLOOR_MS:-${LAT_FLOOR_MS:-250}}"
}

lat_ratio_n() {
  printf '%s\n' "${LASTDB_PROBE_LAT_RATIO:-${LAT_RATIO:-3}}"
}

lat_abs_max_ms() {
  printf '%s\n' "${LASTDB_PROBE_LAT_ABS_MAX_MS:-${LAT_ABS_MAX_MS:-20000}}"
}

# rc 0 = both positive integers and both <= floor (noise).
lat_pair_both_under_floor() {
  local cand="${1:-}" base="${2:-}" floor
  floor="$(lat_floor_ms)"
  lat_pair_measurable "$cand" "$base" || return 1
  [ "$cand" -le "$floor" ] 2>/dev/null || return 1
  [ "$base" -le "$floor" ] 2>/dev/null || return 1
  return 0
}

# rc 0 = both cold or both hot (non-empty).
lat_thermal_same() {
  local c="${1:-}" b="${2:-}"
  [ -n "$c" ] && [ -n "$b" ] || return 1
  [ "$c" = "$b" ] || return 1
  case "$c" in
    cold|hot) return 0 ;;
  esac
  return 1
}

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
  # Both under the floor is noise, not a ratio (2026-08-26 50ms baseline).
  lat_pair_both_under_floor "$cand" "$base" && return 0
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

# Per-op 3× like-to-like. $1=op $2=cand_ms $3=base_ms $4=cand_thermal $5=base_thermal
# Mixed thermal must not RED. Both-under-floor is GREEN noise.
# rc 0 = within bar; rc 1 = RED. Prints one line to stdout.
lat_op_like_to_like_within_bar() {
  local op="$1" cand="$2" base="$3" c_th="${4:-}" b_th="${5:-}"
  local floor ratio absmax
  floor="$(lat_floor_ms)"
  ratio="$(lat_ratio_n)"
  absmax="$(lat_abs_max_ms)"

  if [ -n "$c_th" ] || [ -n "$b_th" ]; then
    if ! lat_thermal_same "$c_th" "$b_th"; then
      printf 'latency %s mixed thermal skipped (cand=%s base=%s; not a bar input)\n' \
        "$op" "${c_th:-unset}" "${b_th:-unset}"
      return 0
    fi
  fi

  if [ "$cand" = "-1" ] || [ -z "$cand" ]; then
    if [ -n "$base" ] && [ "$base" != "-1" ]; then
      printf 'latency %s RED: unmeasurable on candidate but baseline measured %sms\n' "$op" "$base"
      return 1
    fi
    printf 'latency %s: unmeasured on candidate and baseline — no bar applied\n' "$op"
    return 0
  fi

  if [ -n "$base" ] && [ "$base" != "-1" ]; then
    if lat_pair_both_under_floor "$cand" "$base"; then
      printf 'latency %s GREEN: candidate=%sms baseline=%sms (both under %sms floor — noise)\n' \
        "$op" "$cand" "$base" "$floor"
      return 0
    fi
    if [ "$cand" -gt "$floor" ] 2>/dev/null \
      && awk -v c="$cand" -v b="$base" -v r="$ratio" 'BEGIN{exit !(c > b*r)}'; then
      printf 'latency %s RED: candidate %sms > %sx baseline %sms (%s-vs-%s)\n' \
        "$op" "$cand" "$ratio" "$base" "${c_th:-hot}" "${b_th:-hot}"
      return 1
    fi
    if [ "$cand" -gt "$absmax" ] 2>/dev/null; then
      if [ "$base" -gt "$absmax" ] 2>/dev/null; then
        printf 'latency %s: candidate %sms AND baseline %sms both exceed the %sms ceiling — pre-existing slowness\n' \
          "$op" "$cand" "$base" "$absmax"
      else
        printf 'latency %s: candidate %sms over the %sms ceiling but within %sx of baseline %sms — WATCH\n' \
          "$op" "$cand" "$absmax" "$ratio" "$base"
      fi
    fi
    printf 'latency %s GREEN: candidate=%sms baseline=%sms (ratio bar %sx above %sms, %s-vs-%s)\n' \
      "$op" "$cand" "$base" "$ratio" "$floor" "${c_th:-hot}" "${b_th:-hot}"
    return 0
  fi
  if [ "$cand" -gt "$absmax" ] 2>/dev/null; then
    printf 'latency %s RED: candidate %sms > absolute ceiling %sms (no baseline to compare)\n' \
      "$op" "$cand" "$absmax"
    return 1
  fi
  printf 'latency %s GREEN: candidate=%sms (no baseline; abs max %sms)\n' "$op" "$cand" "$absmax"
  return 0
}

# Full probe bars. Args:
#   $1..$4  cold cand/base point, cold cand/base scan
#   $5..$10 hot cand/base point, hot cand/base scan, hot cand/base write
# Write is hot-only. Geo-mean uses the hot triple only.
# rc 0 = all like-to-like GREEN; rc 1 = RED.
lat_apply_like_to_like_bars() {
  local cold_c_pt="$1" cold_b_pt="$2" cold_c_sc="$3" cold_b_sc="$4"
  local hot_c_pt="$5" hot_b_pt="$6" hot_c_sc="$7" hot_b_sc="$8"
  local hot_c_wr="$9" hot_b_wr="${10}"
  local red=0 out rc

  out="$(lat_op_like_to_like_within_bar "cold point-read" "$cold_c_pt" "$cold_b_pt" cold cold)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  out="$(lat_op_like_to_like_within_bar "cold scan" "$cold_c_sc" "$cold_b_sc" cold cold)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  out="$(lat_op_like_to_like_within_bar "hot point-read" "$hot_c_pt" "$hot_b_pt" hot hot)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  out="$(lat_op_like_to_like_within_bar "hot scan" "$hot_c_sc" "$hot_b_sc" hot hot)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  out="$(lat_op_like_to_like_within_bar "hot write" "$hot_c_wr" "$hot_b_wr" hot hot)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  out="$(lat_correlated_within_bar "$hot_c_pt" "$hot_b_pt" "$hot_c_sc" "$hot_b_sc" "$hot_c_wr" "$hot_b_wr")"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || red=1

  [ "$red" -eq 0 ]
}
