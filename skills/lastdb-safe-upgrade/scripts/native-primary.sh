#!/usr/bin/env bash
# Local upgrade route for current native homes.
NATIVE_PRIMARY_OWNER=""

native_primary_route() {
  local marker="$PRIMARY_HOME/data/laststore-pack-node-v1" header
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  IFS= read -r header <"$marker" || return 1
  [[ "$header" =~ ^format=([1-9][0-9]{0,3})$ ]] && [ "${BASH_REMATCH[1]}" -ge 15 ]
}

native_socket_get() {
  curl -fsS --max-time 10 --unix-socket "$PRIMARY_SOCK" \
    -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' "http://x$1"
}

native_assert_same_format() {
  python3 "$_SCRIPT_DIR/native-upgrade-format.py" "$PRIMARY_HOME" \
    "${LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR:-$HOME/.cache/edgevector-git/lastdb.git}" \
    "$(basename -- "$OLD_PROGRAM_DIR")" "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
    || die "native upgrade cannot proceed in place"
}

native_primary_qualify() {
  [ "${LASTDB_SAFE_UPGRADE_ZERO_LIVE_SOAK:-0}" = 0 ] \
    || die "native upgrade requires the normal five-minute soak"
  detect_live_venue
  [ "$VENUE" = programs ] || die "native upgrade requires the supervised programs venue"
  native_assert_same_format
  python3 "$_SCRIPT_DIR/native-upgrade-release.py" "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
    "$CAND_VER" "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN" || die "native upgrade release qualification failed"
}

native_check_program_consumer() {
  local program="$1" service="$2" pid="$3" users plist executable label
  users="$(lsof -nP -t "$program" | sort -u)" || return 1
  [ "$users" = "$pid" ] || return 1
  for plist in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$plist" ] || continue
    executable="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null)" || continue
    if [ "$executable" = "$program" ] || [ "$executable" = "$PRIMARY_HOME/current/lastdbd" ]; then
      label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null)" || return 1
      if [ "$service" != "gui/$(id -u)/$label" ] && lastdb_launchd_job_loaded launchctl "gui/$(id -u)/$label"; then
        return 1
      fi
    fi
  done
}

native_primary_identity() {
  native_socket_get /api/system/boot-identity | jq -er --argjson pid "$1" --arg build "$2" '
    select(.pid == $pid and .build == $build)
    | .process_start_ts | select(type == "number" and . > 0 and . == floor)'
}

native_confirm_serving() {
  local service="$1" build="$2" pid start
  pid="$(live_unix_socket_health_pid "$PRIMARY_SOCK")" || return 1
  [ "$pid" = "$(lastdb_launchd_job_pid launchctl "$service")" ] || return 1
  start="$(native_primary_identity "$pid" "$build")" || return 1
  native_socket_get /api/db/native-status | jq -e '
    .native_disk | .writer_failed == false and (.cleanup | type == "object" and .last_error == null)' >/dev/null || return 1
  [ "$(native_socket_get /api/system/auto-identity | jq -er .user_hash)" = "$NATIVE_PRIMARY_OWNER" ] || return 1
  printf '%s %s\n' "$pid" "$start"
}

native_primary_preflight() {
  local service
  service="gui/$(id -u)/$LAUNCHD_LABEL"
  assert_launchd_label_usable
  NATIVE_PRIMARY_OWNER="$(native_socket_get /api/system/auto-identity | jq -er '.user_hash | select(test("^[0-9a-f]{32}$"))')" \
    || die "cannot read the native primary owner"
  native_confirm_serving "$service" "$CURRENT_VER" >/dev/null || die "native primary is unhealthy or unsupervised"
  primary_brain_and_secret_ok || die "Brain or LastSecrets locator could not be read"
}

native_primary_soak() {
  local service session pid started now
  service="gui/$(id -u)/$LAUNCHD_LABEL"
  session="$(native_confirm_serving "$service" "$CAND_VER")" || die "new primary is unhealthy or unsupervised"
  pid="${session%% *}"
  [ "$pid" != "$OLD_PRIMARY_PID" ] || die "the old daemon is still serving"
  LASTDB_LIVE_CONFIG_ENFORCE=1 lastdb_live_config_drift_check "$LAUNCHD_PLIST" "$pid" \
    || die "the new primary did not load the LaunchAgent environment"
  primary_brain_and_secret_ok || die "the new primary cannot read Brain and LastSecrets locators"
  started="$(date +%s)"
  while :; do
    [ "$(native_confirm_serving "$service" "$CAND_VER")" = "$session" ] \
      || die "the primary lost health or restarted during the soak"
    enforce_rss_under_limit "$(rss_mb_of_pid "$pid")" live || die "the primary is over its memory guard"
    now="$(date +%s)"
    [ "$((now - started))" -ge 300 ] && break
    sleep 5
  done
  primary_brain_and_secret_ok || die "the new primary cannot read Brain and LastSecrets locators after the soak"
  log "native primary passed the five-minute health check"
}

run_native_primary() {
  # Inherit the standard driver and its owner lock, time bounds, and recovery.
  local limit probe_limit program
  native_primary_qualify
  assert_candidate_class_ok "$CANDIDATE_BIN" "$CAND_VER" "$OLD_PROGRAM_DIR/lastdbd" \
    || die "native candidate failed the binary class checks"
  for program in "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN"; do
    codesign --verify --strict "$program" || die "native candidate failed macOS code verification"
  done
  limit="$(resolve_rss_limit_mb)"
  probe_limit="$(rss_fail_threshold_mb "$limit")"
  python3 "$_SCRIPT_DIR/native-primary-probe.py" "$OLD_PROGRAM_DIR/lastdbd" \
    "$CANDIDATE_BIN" "$probe_limit" "$RSS_SETTLE_SECS" "$RSS_SAMPLE_SECS" \
    || die "native candidate failed the generated database reopen"
  native_primary_preflight
  if [ "$PROBE_ONLY" -eq 1 ]; then
    echo "VERDICT: GREEN_PROBE_ONLY"
    return 0
  fi
  [ "$ASSUME_YES" -eq 1 ] && [ "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-0}" = 1 ] \
    || die "native live upgrades require the supervised Loom cutover"
  assert_final_candidate_binding
  native_assert_same_format
  live_install_programs
  native_primary_soak
  write_cutover_recovery_state cutover-green false
  echo "VERDICT: GREEN"
}
