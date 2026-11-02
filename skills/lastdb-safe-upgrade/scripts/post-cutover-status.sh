#!/usr/bin/env bash
# Read one captured /api/status response. No work runs at source.

post_cutover_status_check() {
  # Args: status.json prelive_cloud_frontier require_cloud.
  local file="$1" minimum_frontier="$2" require_cloud="$3"
  local verdict sample_verdict
  verdict="$(jq -r \
    --argjson minimum_frontier "$minimum_frontier" \
    --argjson require_cloud "$require_cloud" '
      if .ok != true then "status-not-ok"
      elif (.status.sync.local_writable // false) != true then "writes-disabled"
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

# Format 7 V2 primary. Args: status.json [v2-status.json stream_id cut].
# Without a V2 file only the native status is checked (the pre-live bar).
# With one, the automatic backup must cover the stopped cut <main>/<cas> on the
# same stream: the candidate backed up every write up to the program change.
post_cutover_status_check_v2() {
  local file="$1" v2="${2:-}" stream="${3:-}" cut="${4:-}" verdict sample_verdict
  local cut_main="" cut_cas=""
  verdict="$(jq -r '
      if .ok != true then "status-not-ok"
      elif (.status | has("sync")) then "not-format7"
      elif .status.durability.observed != true then "cloud-unobserved"
      elif .status.durability.automatic_enabled != true then "cloud-disabled"
      elif .status.durability.degraded != null then "cloud-degraded"
      elif .status.durability.accepted_backup_recorded != true then "cloud-no-accepted-backup"
      else "GREEN" end
    ' "$file" 2>/dev/null)" || verdict="status-invalid"
  if [ "$verdict" = GREEN ] && [ -n "$v2" ]; then
    case "$cut" in */*) cut_main="${cut%/*}"; cut_cas="${cut#*/}" ;; esac
    case "$cut_main$cut_cas" in ''|*[!0-9]*) verdict="cut-invalid" ;; esac
  fi
  if [ "$verdict" = GREEN ] && [ -n "$v2" ]; then
    verdict="$(jq -r --arg stream "$stream" \
      --argjson cut_main "$cut_main" --argjson cut_cas "$cut_cas" '
        .automatic_backup.last_backed_up_frontiers as $backed |
        if .ok != true then "v2-status-not-ok"
        elif .automatic_backup_enabled != true or .automatic_backup.enabled != true then "cloud-disabled"
        elif .automatic_backup.paused != null then "cloud-paused"
        elif .blocked_reason != null then "cloud-blocked"
        elif .mutation_log.gap != null then "cloud-log-gap"
        elif .last_accepted_backup.begin.job.stream.stream_id != $stream then "cloud-stream-changed"
        elif ($backed.main | type) != "number" or ($backed.cas | type) != "number" then "cloud-backup-pending"
        elif $backed.main < $cut_main or $backed.cas < $cut_cas then "cloud-backup-pending"
        else "GREEN" end
      ' "$v2" 2>/dev/null)" || verdict="v2-status-invalid"
  fi
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
    POST_CUTOVER_STATUS=cloud-unobserved|\
    POST_CUTOVER_STATUS=cloud-backup-pending|\
    POST_CUTOVER_STATUS=cloud-log-gap|\
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
