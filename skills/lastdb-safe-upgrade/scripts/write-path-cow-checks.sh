#!/usr/bin/env bash
# Pure Table-5 classifiers for the write-path CoW probe.
# Sourced by write-path-cow-probe.sh and unit tests. No side effects at source.
#
# GREEN = T0 ack: persist spawn-only, sync_capture encode-only, no Purge in
# the timed batch, purge_barrier ≈ 0, warm p50 < 50 ms / p95 < 100 ms.
# RED = incumbent-shaped: seconds-scale ack and/or persist/T2/purge on the
# request. A harness that cannot fail the status quo cannot pass a candidate.
#
# bash 3.2 compatible (macOS /bin/bash).

# Resolve a live-home path. Args: candidate data-dir, live home (default ~/.lastdb).
# rc 0 = the data-dir IS the live home (must refuse). rc 1 = isolated.
write_path_data_dir_is_live_home() {
  local data_dir="${1:-}"
  local live_home="${2:-${LASTDB_HOME:-$HOME/.lastdb}}"
  [ -n "$data_dir" ] || return 1
  local rp lp
  case "$data_dir" in
    "~/.lastdb"|"$HOME/.lastdb") return 0 ;;
  esac
  rp="$(cd "$data_dir" 2>/dev/null && pwd -P)" || rp="$data_dir"
  lp="$(cd "$live_home" 2>/dev/null && pwd -P)" || lp="$live_home"
  [ "$rp" = "$lp" ]
}

# Numeric ms is "seconds-scale" when >= 1000.
write_path_ms_is_seconds_scale() {
  local ms="${1:-0}"
  [ "$ms" -ge 1000 ] 2>/dev/null
}

# persist_mode is spawn-only (T1 off the request).
write_path_persist_is_spawn_only() {
  local mode="${1:-}"
  case "$mode" in
    spawn-only|spawn_only|spawn) return 0 ;;
    *) return 1 ;;
  esac
}

# sync_capture_mode is encode-only (T2 not awaited).
write_path_sync_capture_is_encode_only() {
  local mode="${1:-}"
  case "$mode" in
    encode-only|encode_only|encode) return 0 ;;
    *) return 1 ;;
  esac
}

# purge_barrier is approximately zero (< 5 ms).
write_path_purge_barrier_is_approx_zero() {
  local ms="${1:-0}"
  [ "$ms" -lt 5 ] 2>/dev/null
}

# Table 5 latency bar: p50 < 50 and p95 < 100.
write_path_warm_latency_within_bar() {
  local p50="${1:-}" p95="${2:-}"
  [ -n "$p50" ] && [ -n "$p95" ] || return 1
  [ "$p50" -lt 50 ] 2>/dev/null || return 1
  [ "$p95" -lt 100 ] 2>/dev/null || return 1
  return 0
}

# Classify one sample. Prints GREEN:/RED: lines. rc 0 = GREEN, rc 1 = RED.
#
# Args (all optional, missing treated as unknown/bad):
#   ack_ms persist_mode sync_capture_mode purge_in_batch purge_barrier_ms
#   p50_ms p95_ms exclusive_purge
#
# persist_mode: spawn-only | awaited | inline
# sync_capture_mode: encode-only | awaited
# purge_in_batch: 0|1
# exclusive_purge: 0|1
write_path_classify_sample() {
  local ack_ms="${1:-}"
  local persist_mode="${2:-}"
  local sync_capture_mode="${3:-}"
  local purge_in_batch="${4:-}"
  local purge_barrier_ms="${5:-}"
  local p50_ms="${6:-}"
  local p95_ms="${7:-}"
  local exclusive_purge="${8:-}"

  local red=0
  local reasons=""

  _wp_add_red() {
    red=1
    if [ -n "$reasons" ]; then
      reasons="${reasons}; $1"
    else
      reasons="$1"
    fi
  }

  if write_path_ms_is_seconds_scale "${ack_ms:-0}"; then
    _wp_add_red "seconds-scale ack (${ack_ms}ms)"
  fi
  if ! write_path_persist_is_spawn_only "$persist_mode"; then
    _wp_add_red "persist ${persist_mode:-unknown} (want spawn-only; T1 on the request)"
  fi
  if ! write_path_sync_capture_is_encode_only "$sync_capture_mode"; then
    _wp_add_red "sync_capture ${sync_capture_mode:-unknown} (want encode-only; T2 on the request)"
  fi
  if [ "${purge_in_batch:-0}" = "1" ] || [ "${purge_in_batch:-}" = "true" ]; then
    _wp_add_red "Purge in the timed batch"
  fi
  if ! write_path_purge_barrier_is_approx_zero "${purge_barrier_ms:-0}"; then
    _wp_add_red "purge_barrier ${purge_barrier_ms}ms (want ≈ 0)"
  fi
  if [ "${exclusive_purge:-0}" = "1" ] || [ "${exclusive_purge:-}" = "true" ]; then
    _wp_add_red "exclusive purge on the request"
  fi
  if [ -n "$p50_ms" ] && [ -n "$p95_ms" ]; then
    if ! write_path_warm_latency_within_bar "$p50_ms" "$p95_ms"; then
      _wp_add_red "warm p50=${p50_ms}ms p95=${p95_ms}ms (want p50<50 p95<100)"
    fi
  elif [ -n "$ack_ms" ]; then
    if ! write_path_warm_latency_within_bar "$ack_ms" "$ack_ms"; then
      _wp_add_red "ack ${ack_ms}ms outside Table 5 bar"
    fi
  fi

  if [ "$red" -ne 0 ]; then
    printf 'RED: incumbent-shaped or off-contract write path (%s)\n' "$reasons"
    return 1
  fi
  printf 'GREEN: Table 5 T0 ack persist=%s sync_capture=%s purge_in_batch=0 purge_barrier=%sms p50=%s p95=%s\n' \
    "$persist_mode" "$sync_capture_mode" "${purge_barrier_ms:-0}" "${p50_ms:-$ack_ms}" "${p95_ms:-$ack_ms}"
  return 0
}

# Classify a JSON sample file (jq). Same fields as write_path_classify_sample.
write_path_classify_json_file() {
  local file="$1"
  [ -f "$file" ] || { echo "RED: missing sample file $file" >&2; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    echo "RED: jq required to classify JSON sample" >&2
    return 1
  fi
  local ack persist sync purge barrier p50 p95 exclusive
  ack="$(jq -r '.ack_ms // empty' "$file")"
  persist="$(jq -r '.persist_mode // .persist // empty' "$file")"
  sync="$(jq -r '.sync_capture_mode // .sync_capture // empty' "$file")"
  purge="$(jq -r 'if .purge_in_batch == true or .purge_in_batch == 1 then 1 else 0 end' "$file")"
  barrier="$(jq -r '.purge_barrier_ms // 0' "$file")"
  p50="$(jq -r '.p50_ms // empty' "$file")"
  p95="$(jq -r '.p95_ms // empty' "$file")"
  exclusive="$(jq -r 'if .exclusive_purge == true or .exclusive_purge == 1 then 1 else 0 end' "$file")"
  write_path_classify_sample "$ack" "$persist" "$sync" "$purge" "$barrier" "$p50" "$p95" "$exclusive"
}
