#!/usr/bin/env bash
# Signed-backup route for the standard Loom upgrade driver.
SIGNED_OWNER=""
SIGNED_POINT=""
SIGNED_LIVE_PID=""
SIGNED_WAIT_SECS=300

signed_primary_route() {
  [ -f "$PRIMARY_HOME/data/laststore-pack-node-v1" ] \
    && [ -f "$PRIMARY_HOME/data/disk-run/accepted-v1/state.json" ] \
    && [ -f "$PRIMARY_HOME/databases/registry.json" ]
}

signed_socket_get() {
  curl -fsS --max-time 10 --unix-socket "$PRIMARY_SOCK" \
    -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' "http://x$1"
}

signed_recovery_point() {
  python3 "$_SCRIPT_DIR/signed-recovery-point.py" point "$PRIMARY_HOME" "$SIGNED_OWNER" "$@"
}

signed_assert_same_format() {
  python3 "$_SCRIPT_DIR/signed-recovery-point.py" format "$PRIMARY_HOME" \
    "${LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR:-$HOME/.cache/edgevector-git/lastdb.git}" \
    "$(basename -- "$OLD_PROGRAM_DIR")" "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
    || die "signed upgrade cannot proceed in place"
}

signed_primary_qualify() {
  [ -z "$STALE_RECOVERY_WAIVER" ] && [ "${LASTDB_SAFE_UPGRADE_ZERO_LIVE_SOAK:-0}" = 0 ] \
    || die "signed upgrade requires a current recovery point and the normal five-minute soak"
  [ "${LASTDB_PROBE_DEV_STAMP_SKIP:-0}" = 0 ] || die "signed upgrade requires a DEV restore check"
  detect_live_venue
  [ "$VENUE" = programs ] || die "signed upgrade requires the supervised programs venue"
  signed_assert_same_format
  python3 "$_SCRIPT_DIR/signed-release.py" "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
    "$CAND_VER" "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN" || die "signed upgrade release qualification failed"
}

signed_check_program_consumer() {
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

signed_refresh_recovery_point() {
  local updated
  updated="$(signed_recovery_point "$1" --min-local "$(jq -er .local <<< "$SIGNED_POINT")" \
    --min-cloud "$(jq -er .cloud <<< "$SIGNED_POINT")")" || die "signed recovery does not cover the current cut"
  [ "$(jq -er .database <<< "$updated")" = "$(jq -er .database <<< "$SIGNED_POINT")" ] \
    || die "the signed recovery database changed"
  SIGNED_POINT="$updated"
}

signed_primary_identity() {
  signed_socket_get /api/system/boot-identity | jq -er --argjson pid "$1" --arg build "$2" '
    select(.pid == $pid and .build == $build)
    | .process_start_ts | select(type == "number" and . > 0 and . == floor)'
}

signed_confirm_serving() {
  local service="$1" build="$2" pid
  pid="$(live_unix_socket_health_pid "$PRIMARY_SOCK")" || return 1
  [ "$pid" = "$(lastdb_launchd_job_pid launchctl "$service")" ] || return 1
  signed_primary_identity "$pid" "$build" >/dev/null || return 1
  signed_socket_get /api/db/native-status | jq -e '
    .native_disk | .writer_failed == false and .cleanup.last_error == null' >/dev/null || return 1
  [ "$(signed_socket_get /api/system/auto-identity | jq -er .user_hash)" = "$SIGNED_OWNER" ] || return 1
  printf '%s\n' "$pid"
}

signed_primary_preflight() {
  local service
  service="gui/$(id -u)/$LAUNCHD_LABEL"
  assert_launchd_label_usable
  SIGNED_OWNER="$(signed_socket_get /api/system/auto-identity | jq -er '.user_hash | select(test("^[0-9a-f]{32}$"))')" \
    || die "cannot read the signed primary owner"
  signed_confirm_serving "$service" "$CURRENT_VER" >/dev/null || die "signed primary is unhealthy or unsupervised"
  primary_brain_and_secret_ok || die "Brain or LastSecrets locator could not be read"
  SIGNED_POINT="$(signed_recovery_point "$SIGNED_WAIT_SECS")" || die "signed production recovery point is unavailable"
  log "signed production recovery point: $(jq -r .cloud <<< "$SIGNED_POINT")"
}

signed_flush_new_write() {
  curl -fsS --max-time 30 --unix-socket "$PRIMARY_SOCK" \
    -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
    -H 'Content-Type: application/json' --data '{}' http://x/api/db/flush \
    | jq -e '.durable == true' >/dev/null || die "the post-upgrade write did not flush"
}

signed_primary_soak() {
  local service started now pid point local_cut cloud_cut database marker
  service="gui/$(id -u)/$LAUNCHD_LABEL"
  local_cut="$(jq -er .local <<< "$SIGNED_POINT")"
  cloud_cut="$(jq -er .cloud <<< "$SIGNED_POINT")"
  database="$(jq -er .database <<< "$SIGNED_POINT")"
  SIGNED_LIVE_PID="$(signed_confirm_serving "$service" "$CAND_VER")" || die "new signed primary is not supervised or healthy"
  [ "$SIGNED_LIVE_PID" != "$OLD_PRIMARY_PID" ] || die "the old daemon is still serving"
  LASTDB_LIVE_CONFIG_ENFORCE=1 lastdb_live_config_drift_check "$LAUNCHD_PLIST" "$SIGNED_LIVE_PID" \
    || die "new signed primary did not load the LaunchAgent environment"
  primary_brain_and_secret_ok || die "new signed primary cannot read Brain and LastSecrets locators"
  marker="verify-signed-upgrade-$(uuidgen | tr 'A-Z' 'a-z')"
  if ! printf '%s\n' '---' 'type: reference' "slug: $marker" 'title: Signed LastDB upgrade' '---' '' \
      'This record verifies automatic signed upload after a supervised upgrade.' \
    | LASTDB_HOME="$PRIMARY_HOME" FOLDDB_SOCKET_PATH="$PRIMARY_SOCK" \
      brain put "$marker" --type reference >/dev/null; then
    die "the post-upgrade Brain write failed"
  fi
  signed_flush_new_write
  local_cut="$(python3 "$_SCRIPT_DIR/signed-recovery-point.py" written "$PRIMARY_HOME" "$database")" \
    || die "cannot read the new local write boundary"
  [ "$local_cut" -gt "$(jq -er .local <<< "$SIGNED_POINT")" ] \
    || die "the post-upgrade write did not enter signed capture"
  cloud_cut="$((cloud_cut + 1))"
  started="$(date +%s)"
  while :; do
    pid="$(signed_confirm_serving "$service" "$CAND_VER")" || die "signed primary lost health during soak"
    [ "$pid" = "$SIGNED_LIVE_PID" ] || die "signed primary restarted during soak"
    enforce_rss_under_limit "$(rss_mb_of_pid "$pid")" live || die "signed primary is over its memory guard"
    now="$(date +%s)"
    [ "$((now - started))" -ge 300 ] && break
    sleep 5
  done
  point="$(signed_recovery_point "$SIGNED_WAIT_SECS" --min-local "$local_cut" --min-cloud "$cloud_cut")" \
    || die "signed cloud prefix did not cover the stopped cut"
  [ "$(jq -er .database <<< "$point")" = "$database" ] \
    && [ "$(signed_confirm_serving "$service" "$CAND_VER")" = "$SIGNED_LIVE_PID" ] \
    && primary_brain_and_secret_ok || die "the signed primary changed after the soak"
  log "signed primary healthy and current through $(jq -r .cloud <<< "$point")"
}

run_signed_primary() {
  # Inherit the standard driver and its owner lock, time bounds, and recovery.
  local limit probe_limit program
  signed_primary_qualify
  assert_candidate_class_ok "$CANDIDATE_BIN" "$CAND_VER" "$OLD_PROGRAM_DIR/lastdbd" \
    || die "signed candidate failed the binary class checks"
  for program in "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN"; do
    codesign --verify --strict "$program" || die "signed candidate failed macOS code verification"
  done
  limit="$(resolve_rss_limit_mb)"
  probe_limit="$(rss_fail_threshold_mb "$limit")"
  python3 "$_SCRIPT_DIR/signed-primary-probe.py" "$OLD_PROGRAM_DIR/lastdbd" \
    "$CANDIDATE_BIN" "$probe_limit" "$RSS_SETTLE_SECS" "$RSS_SAMPLE_SECS" \
    || die "signed candidate failed the generated database reopen"
  signed_primary_preflight
  if [ "$PROBE_ONLY" -eq 1 ]; then
    echo "VERDICT: GREEN_PROBE_ONLY"
    return 0
  fi
  [ "$ASSUME_YES" -eq 1 ] && [ "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-0}" = 1 ] \
    || die "signed live upgrades require the supervised Loom cutover"
  assert_final_candidate_binding
  signed_assert_same_format
  live_install_programs
  signed_primary_soak
  write_cutover_recovery_state cutover-green false
  echo "VERDICT: GREEN"
}
