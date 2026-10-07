#!/usr/bin/env bash
# Paired hot latency samples for the safe-upgrade driver.
# The caller supplies now_ms, run_op_with_deadline, median_of, and warn.

lat_paired_sample_count_valid() {
  case "${LAT_SAMPLES:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$LAT_SAMPLES" -ge 2 ] && [ $((LAT_SAMPLES % 2)) -eq 0 ]
}

# $1=operation $2=argument $3=label $4=sample number $5=side.
# The caller reads LAT_PAIRED_SAMPLE_MS. A deadline counts as its full duration.
lat_paired_sample_once() {
  local fn="$1" arg="$2" label="$3" i="$4" side="$5"
  local t0 t1 rc=0
  t0="$(now_ms)"
  run_op_with_deadline "$LAT_OP_TIMEOUT_SECS" "$fn" "$arg" || rc=$?
  t1="$(now_ms)"
  if [ "$rc" -eq 124 ]; then
    warn "latency $label $side sample $i hit the ${LAT_OP_TIMEOUT_SECS}s deadline"
    LAT_PAIRED_SAMPLE_MS=$((LAT_OP_TIMEOUT_SECS * 1000))
  elif [ "$rc" -ne 0 ]; then
    warn "latency $label $side sample $i failed (rc=$rc)"
    LAT_PAIRED_SAMPLE_MS=-1
  else
    LAT_PAIRED_SAMPLE_MS=$((t1 - t0))
  fi
}

# Measure candidate and baseline on adjacent calls. Alternate which runs first
# so a slower first call does not always charge the same daemon. Return medians
# in LAT_PAIR_* globals, and log every raw sample. N must be even.
# $1=operation $2=candidate argument $3=baseline argument $4=label.
lat_measure_paired_medians_ms() {
  local fn="$1" cand_arg="$2" base_arg="$3" label="$4"
  local i cand_vals="" base_vals="" cand_raw="" base_raw=""
  local cand_ms base_ms
  if ! lat_paired_sample_count_valid; then
    warn "latency $label: sample count must be a positive even integer"
    return 2
  fi

  for i in $(seq 1 "$LAT_SAMPLES"); do
    if [ $((i % 2)) -eq 1 ]; then
      lat_paired_sample_once "$fn" "$cand_arg" "$label" "$i" candidate
      cand_ms="$LAT_PAIRED_SAMPLE_MS"
      lat_paired_sample_once "$fn" "$base_arg" "$label" "$i" baseline
      base_ms="$LAT_PAIRED_SAMPLE_MS"
    else
      lat_paired_sample_once "$fn" "$base_arg" "$label" "$i" baseline
      base_ms="$LAT_PAIRED_SAMPLE_MS"
      lat_paired_sample_once "$fn" "$cand_arg" "$label" "$i" candidate
      cand_ms="$LAT_PAIRED_SAMPLE_MS"
    fi
    cand_raw="${cand_raw:+$cand_raw,}$cand_ms"
    base_raw="${base_raw:+$base_raw,}$base_ms"
    [ "$cand_ms" -lt 0 ] || cand_vals="${cand_vals:+$cand_vals }$cand_ms"
    [ "$base_ms" -lt 0 ] || base_vals="${base_vals:+$base_vals }$base_ms"
  done

  LAT_PAIR_CAND_MS=-1
  LAT_PAIR_BASE_MS=-1
  # Values contain only measured integer milliseconds, so intentional split is safe.
  if [ -n "$cand_vals" ]; then
    # shellcheck disable=SC2086
    LAT_PAIR_CAND_MS="$(median_of $cand_vals)"
  fi
  if [ -n "$base_vals" ]; then
    # shellcheck disable=SC2086
    LAT_PAIR_BASE_MS="$(median_of $base_vals)"
  fi
  warn "latency $label paired samples: candidate=[$cand_raw] baseline=[$base_raw] medians=${LAT_PAIR_CAND_MS}/${LAT_PAIR_BASE_MS}ms"
}
