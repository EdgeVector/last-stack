#!/usr/bin/env bash
# Read one captured /api/status response. No work runs at source.

post_cutover_status_check() {
  # Args: status.json minimum_cloud_frontier require_cloud max_meter_bytes.
  local file="$1" minimum_frontier="$2" require_cloud="$3" max_meter_bytes="$4"
  local verdict
  verdict="$(jq -r \
    --argjson minimum_frontier "$minimum_frontier" \
    --argjson require_cloud "$require_cloud" \
    --argjson max_meter_bytes "$max_meter_bytes" '
      if .ok != true then "status-not-ok"
      elif (.status.resident.persist_lane_failures // -1) != 0 then "persist-lane-failure"
      elif (.status.resident.deferred_persist_failed // -1) != 0 then "deferred-persist-failure"
      elif (.status.sync.local_writable // false) != true then "writes-disabled"
      elif (.status.sync.capture.automatic_compactions.keep_small.allocated_bytes // -1) < 0 then "meter-size-unavailable"
      elif .status.sync.capture.automatic_compactions.keep_small.allocated_bytes > $max_meter_bytes then "meter-group-over-cap"
      elif $require_cloud == 1 and (.status.sync.enabled // false) != true then "cloud-disabled"
      elif $require_cloud == 1 and (.status.sync.recording_local_changes // false) != true then "cloud-not-recording"
      elif $require_cloud == 1 and (.status.sync.mutation_log_capture_registered // false) != true then "cloud-capture-unregistered"
      elif $require_cloud == 1 and .status.sync.sync_degraded != false then "cloud-degraded"
      elif $require_cloud == 1 and (.status.sync.mutation_log_frontier_f // 0) <= $minimum_frontier then "cloud-frontier-stale"
      else "GREEN" end
    ' "$file" 2>/dev/null)" || verdict="status-invalid"
  printf 'POST_CUTOVER_STATUS=%s\n' "$verdict"
  [ "$verdict" = GREEN ]
}

prelive_cloud_status_check() {
  # Args: status.json now_s max_lag_s. Reads the OLD primary's status before the
  # live step. The soak needs a frontier newer than the first post-cutover write
  # within SOAK_MAX_SECS, so a frontier already hours behind cannot pass it.
  # The frontier is epoch nanoseconds. Any doubt is a refusal. Cloud Sync off is
  # not applicable (the soak does not require cloud then).
  local file="$1" now_s="$2" max_lag_s="$3"
  local verdict
  case "$now_s$max_lag_s" in
    ''|*[!0-9]*) printf 'PRELIVE_CLOUD=status-invalid\n'; return 1 ;;
  esac
  [ -n "$now_s" ] && [ -n "$max_lag_s" ] \
    || { printf 'PRELIVE_CLOUD=status-invalid\n'; return 1; }
  verdict="$(jq -r \
    --argjson now_s "$now_s" \
    --argjson max_lag_s "$max_lag_s" '
      if .ok != true then "status-not-ok"
      elif (.status.sync.enabled | type) != "boolean" then "status-invalid"
      elif .status.sync.enabled == false then "cloud-off"
      elif .status.sync.sync_degraded != false then "cloud-degraded"
      elif (.status.sync.mutation_log_frontier_f | type) != "number" then "cloud-frontier-unavailable"
      elif .status.sync.mutation_log_frontier_f < (($now_s - $max_lag_s) * 1000000000) then "cloud-frontier-lag"
      elif .status.sync.mutation_log_frontier_f > (($now_s + $max_lag_s) * 1000000000) then "cloud-frontier-in-future"
      else "GREEN" end
    ' "$file" 2>/dev/null)" || verdict="status-invalid"
  [ -n "$verdict" ] || verdict="status-invalid"
  printf 'PRELIVE_CLOUD=%s\n' "$verdict"
  [ "$verdict" = GREEN ] || [ "$verdict" = cloud-off ]
}

post_cutover_status_retryable() {
  case "$1" in
    POST_CUTOVER_STATUS=cloud-capture-unregistered|\
    POST_CUTOVER_STATUS=cloud-degraded|\
    POST_CUTOVER_STATUS=cloud-frontier-stale) return 0 ;;
    *) return 1 ;;
  esac
}

post_cutover_soak_green_in_bounds() {
  # A status request can finish after the loop's top-of-pass deadline check.
  local elapsed="$1" minimum="$2" maximum="$3" confirmed="$4"
  [ "$confirmed" -eq 1 ] && [ "$elapsed" -ge "$minimum" ] && [ "$elapsed" -le "$maximum" ]
}
