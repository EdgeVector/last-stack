#!/usr/bin/env bash
# Read one captured /api/status response. No work runs at source.

post_cutover_status_check() {
  # Args: status.json prelive_cloud_frontier require_cloud max_meter_bytes [empty_home].
  # empty_home=1 is Case 2 (Tom, 2026-10-14): the home lists zero schemas. The
  # lastdb source (sync_probe.rs) shows no `sync.capture` object on a node with
  # Cloud Sync off until the first compaction cadence runs. So an ABSENT meter
  # size is accepted only when status.sync.enabled is exactly false AND
  # status.sync.capture is absent or null. A capture object without a size, or a
  # sync state that is not known, stays RED. A size that is present is still
  # compared with the cap. The default is 0 (Case 1 and the pre-live bar).
  local file="$1" minimum_frontier="$2" require_cloud="$3" max_meter_bytes="$4" empty_home="${5:-0}"
  local verdict sample_verdict
  verdict="$(jq -r \
    --argjson minimum_frontier "$minimum_frontier" \
    --argjson require_cloud "$require_cloud" \
    --argjson max_meter_bytes "$max_meter_bytes" \
    --argjson empty_home "$empty_home" '
      if .ok != true then "status-not-ok"
      elif (.status.resident.persist_lane_failures // -1) != 0 then "persist-lane-failure"
      elif (.status.resident.deferred_persist_failed // -1) != 0 then "deferred-persist-failure"
      elif (.status.sync.local_writable // false) != true then "writes-disabled"
      elif ((.status.sync.capture.automatic_compactions.keep_small.allocated_bytes // -1) < 0)
        and ($empty_home != 1 or .status.sync.enabled != false or .status.sync.capture != null) then "meter-size-unavailable"
      elif .status.sync.capture.automatic_compactions.keep_small.allocated_bytes > $max_meter_bytes then "meter-group-over-cap"
      elif $require_cloud == 1 and (.status.sync.enabled // false) != true then "cloud-disabled"
      elif $require_cloud == 1 and (.status.sync.recording_local_changes // false) != true then "cloud-not-recording"
      elif $require_cloud == 1 and (.status.sync.mutation_log_capture_registered // false) != true then "cloud-capture-unregistered"
      elif $require_cloud == 1 and .status.sync.sync_degraded != false then "cloud-degraded"
      elif $require_cloud == 1 and (.status.sync.mutation_log_frontier_f | type) != "number" then "cloud-frontier-unavailable"
      elif $require_cloud == 1 and .status.sync.mutation_log_frontier_f < $minimum_frontier then "cloud-frontier-regressed"
      else "GREEN" end
    ' "$file" 2>/dev/null)" || verdict="status-invalid"
  # An unknown or future clock must not wait behind a retryable cloud failure.
  # A stale clock leaves an existing health failure verdict in force.
  if sample_verdict="$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/cloud-recovery-status.py" \
    --status "$file" --max-age-secs 300 --status-sample-only 2>/dev/null)"; then
    [ "$sample_verdict" = status-sample-fresh ] || verdict="status-invalid"
  else
    case "$sample_verdict" in
      status-sample-missing|status-sample-invalid|status-sample-future)
        verdict="$sample_verdict" ;;
      status-sample-stale)
        [ "$verdict" != GREEN ] || verdict="$sample_verdict" ;;
      *) verdict="status-invalid" ;;
    esac
  fi
  printf 'POST_CUTOVER_STATUS=%s\n' "$verdict"
  [ "$verdict" = GREEN ]
}

post_cutover_status_retryable() {
  case "$1" in
    POST_CUTOVER_STATUS=status-sample-stale|\
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
