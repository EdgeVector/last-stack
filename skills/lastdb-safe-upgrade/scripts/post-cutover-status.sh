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
  # within SOAK_MAX_SECS, so a stalled uploader cannot pass it.
  #
  # The test is a BACKLOG, not an age. The frontier is the time of the last
  # published write, so it stops while a node is idle: an idle node that is fully
  # caught up (mutation_log_lag == 0) has a frontier hours old and nothing at
  # risk. fold's rpo_secs_from_frontier makes the same call ("an idle node whose F
  # stopped advancing hours ago is at RPO 0"). Only a number 0 counts as caught
  # up. Text, null or an absent lag is an unknown backlog, so the age rule applies.
  #
  # The age is read from mutation_log_published_through, the cloud-confirmed
  # watermark. mutation_log_frontier_f is the max across writers and includes
  # frontiers sealed by other writers that never reached the cloud, so it is only
  # the fallback for a node that does not serve published_through. The frontier is
  # epoch nanoseconds. A future frontier (a unit or clock error) is refused even at
  # lag 0, because the soak compares against the same unit. Any doubt is a refusal.
  # Cloud Sync off is not applicable (the soak does not require cloud then).
  #
  # Prints one line: PRELIVE_CLOUD=<verdict>, plus " frontier_age_s=<n>
  # mutation_log_lag=<n>" when the verdict rests on the frontier. The age is
  # now minus the frontier, in seconds (negative when the frontier is in the future).
  local file="$1" now_s="$2" max_lag_s="$3"
  local out verdict age lag
  case "$now_s$max_lag_s" in
    ''|*[!0-9]*) printf 'PRELIVE_CLOUD=status-invalid\n'; return 1 ;;
  esac
  [ -n "$now_s" ] && [ -n "$max_lag_s" ] \
    || { printf 'PRELIVE_CLOUD=status-invalid\n'; return 1; }
  out="$(jq -r \
    --argjson now_s "$now_s" \
    --argjson max_lag_s "$max_lag_s" '
      .status.sync.mutation_log_published_through as $published
      | .status.sync.mutation_log_frontier_f as $frontier_f
      | (if ($published | type) == "number" then $published else $frontier_f end) as $f
      | .status.sync.mutation_log_lag as $lag
      | (if ($f | type) == "number" then (($now_s - (($f / 1000000000) | floor)) | tostring) else "-" end) as $age
      | (if ($lag | type) == "number" then ($lag | tostring) else "-" end) as $lag_text
      | (if .ok != true then "status-not-ok"
         elif (.status.sync.enabled | type) != "boolean" then "status-invalid"
         elif .status.sync.enabled == false then "cloud-off"
         elif .status.sync.sync_degraded != false then "cloud-degraded"
         elif ($f | type) != "number" then "cloud-frontier-unavailable"
         elif $f > (($now_s + $max_lag_s) * 1000000000) then "cloud-frontier-in-future"
         elif ($lag | type) == "number" and $lag == 0 then "GREEN"
         elif $f < (($now_s - $max_lag_s) * 1000000000) then "cloud-frontier-lag"
         else "GREEN" end) as $verdict
      | $verdict + " " + $age + " " + $lag_text
    ' "$file" 2>/dev/null)" || out=""
  [ -n "$out" ] || out="status-invalid - -"
  read -r verdict age lag <<EOF
$out
EOF
  case "$verdict" in
    GREEN|cloud-frontier-lag|cloud-frontier-in-future)
      printf 'PRELIVE_CLOUD=%s frontier_age_s=%s mutation_log_lag=%s\n' "$verdict" "$age" "$lag" ;;
    *)
      printf 'PRELIVE_CLOUD=%s\n' "$verdict" ;;
  esac
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

post_cutover_soak_evidence() {
  # Args: status.json last_verdict. One phrase for the soak RED message: the last
  # verdict and the cloud fields the soak waited on. Never fails, never prints a
  # whole error text (the file itself is kept as evidence).
  local file="$1" verdict="${2:-unavailable}" sync
  sync="$(jq -c '.status.sync | {mutation_log_frontier_f, mutation_log_last_durable_frontier, sync_degraded, last_error: (.last_error | if type == "string" then .[0:200] else . end)}' "$file" 2>/dev/null || true)"
  [ -n "$sync" ] || sync=unavailable
  printf 'last verdict %s; last cloud status %s' "$verdict" "$sync"
}

post_cutover_soak_green_in_bounds() {
  # A status request can finish after the loop's top-of-pass deadline check.
  local elapsed="$1" minimum="$2" maximum="$3" confirmed="$4"
  [ "$confirmed" -eq 1 ] && [ "$elapsed" -ge "$minimum" ] && [ "$elapsed" -le "$maximum" ]
}
