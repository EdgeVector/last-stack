#!/usr/bin/env bash
# Read one captured /api/status response. No work runs at source.

post_cutover_status_check() {
  # Args: status.json prelive_cloud_frontier require_cloud max_meter_bytes.
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
      elif $require_cloud == 1 and (.status.sync.mutation_log_frontier_f | type) != "number" then "cloud-frontier-unavailable"
      elif $require_cloud == 1 and .status.sync.mutation_log_frontier_f < $minimum_frontier then "cloud-frontier-regressed"
      else "GREEN" end
    ' "$file" 2>/dev/null)" || verdict="status-invalid"
  printf 'POST_CUTOVER_STATUS=%s\n' "$verdict"
  [ "$verdict" = GREEN ]
}

post_cutover_status_retryable() {
  case "$1" in
    POST_CUTOVER_STATUS=cloud-capture-unregistered|\
    POST_CUTOVER_STATUS=cloud-degraded|\
    POST_CUTOVER_STATUS=cloud-frontier-unavailable|\
    POST_CUTOVER_STATUS=cloud-frontier-regressed) return 0 ;;
    *) return 1 ;;
  esac
}

post_cutover_soak_green_in_bounds() {
  # A status request can finish after the loop's top-of-pass deadline check.
  local elapsed="$1" minimum="$2" maximum="$3" confirmed="$4"
  [ "$confirmed" -eq 1 ] && [ "$elapsed" -ge "$minimum" ] && [ "$elapsed" -le "$maximum" ]
}
