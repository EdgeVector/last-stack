#!/usr/bin/env bash
# Programs venue for the native primary, whose LaunchAgent runs
# $PRIMARY_HOME/native-run-v2-programs/<full oid>/lastdbd.
# Sourced by safe-upgrade-lastdb.sh; uses its globals and log/warn/die.
#
# The install matches the manual switch of 2026-11-01: the candidate pair goes
# into its own program directory, the plist ProgramArguments:0 names it, and
# last-stack-lastdb-current points $PRIMARY_HOME/current and the shims at it.
# The old program directory is never changed, so it is the saved rollback pair.
#
# Backup stays on at every step. Before the strict stop the OLD build must show
# the recovery point in its status (signed-log-backup.sh); the soak checks that
# the new build uploads and snapshots again.

PROGRAMS_DIR=""
OLD_PROGRAM_DIR=""
NEW_PROGRAM_DIR=""
PROGRAMS_REVIVE_HOLD="${LASTDBD_GUARD_REVIVE_HOLD_FILE:-$PRIMARY_HOME/monitoring/lastdbd-revive.hold}"
PROGRAMS_REVIVE_HOLD_OWNED=0
PROGRAMS_PLIST_SWITCHED=0

# Echo the old program directory when the plist runs a pair from the programs
# directory of this home. The path must be physical and named by a full oid.
programs_old_dir_from_plist() {
  local prog dir parent name
  prog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD_PLIST" 2>/dev/null)" || return 1
  prog="$(lastdb_programs_daemon_path "$PRIMARY_HOME" "$prog")" || return 1
  [ "$(basename -- "$prog")" = lastdbd ] || return 1
  dir="$(dirname -- "$prog")"
  parent="$(dirname -- "$dir")"
  name="$(basename -- "$dir")"
  [[ "$name" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "$parent" = "$PRIMARY_HOME/native-run-v2-programs" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -L "$parent" ] || return 1
  [ "$(CDPATH= cd -- "$dir" && pwd -P)" = "$dir" ] || return 1
  [ -x "$dir/lastdbd" ] && [ -x "$dir/lastdb" ] || return 1
  printf '%s\n' "$dir"
}

programs_hold_revive() {
  if [ -e "$PROGRAMS_REVIVE_HOLD" ] || [ -L "$PROGRAMS_REVIVE_HOLD" ]; then
    [ -f "$PROGRAMS_REVIVE_HOLD" ] && [ ! -L "$PROGRAMS_REVIVE_HOLD" ] \
      || die "the memory guard revive hold path is unsafe: $PROGRAMS_REVIVE_HOLD"
    log "memory guard revive hold already present (not owned by this run)"
    return 0
  fi
  mkdir -p "$(dirname -- "$PROGRAMS_REVIVE_HOLD")"
  printf 'lastdb-safe-upgrade pid=%s\n' "$$" >"$PROGRAMS_REVIVE_HOLD" \
    || die "cannot write the memory guard revive hold"
  PROGRAMS_REVIVE_HOLD_OWNED=1
  log "memory guard revive hold set: $PROGRAMS_REVIVE_HOLD"
}

programs_release_revive_hold() {
  [ "$PROGRAMS_REVIVE_HOLD_OWNED" = 1 ] || return 0
  if [ -f "$PROGRAMS_REVIVE_HOLD" ] && [ ! -L "$PROGRAMS_REVIVE_HOLD" ] \
    && grep -q "^lastdb-safe-upgrade pid=$$\$" "$PROGRAMS_REVIVE_HOLD" 2>/dev/null; then
    rm -f -- "$PROGRAMS_REVIVE_HOLD"
  fi
  PROGRAMS_REVIVE_HOLD_OWNED=0
}

# Point the plist and $PRIMARY_HOME/current at one program directory.
programs_point_at() {
  local dir="$1" tmp program current_tool="$_SCRIPT_DIR/../../../bin/last-stack-lastdb-current"
  [ -x "$current_tool" ] || current_tool="$(command -v last-stack-lastdb-current)" || return 1
  program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD_PLIST" 2>/dev/null)" || return 1
  if [ "$program" = "$PRIMARY_HOME/current/lastdbd" ]; then
    "$current_tool" set --lastdb-home "$PRIMARY_HOME" --bin-dir "$dir" >/dev/null 2>&1 \
      && [ "$(lastdb_programs_daemon_path "$PRIMARY_HOME" "$program")" = "$dir/lastdbd" ]
    return $?
  fi
  tmp="$(dirname -- "$LAUNCHD_PLIST")/.$(basename -- "$LAUNCHD_PLIST").programs.$$"
  rm -f -- "$tmp"
  cp -p "$LAUNCHD_PLIST" "$tmp" || return 1
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $dir/lastdbd" "$tmp" >/dev/null \
    && plutil -lint "$tmp" >/dev/null \
    && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$tmp")" = "$dir/lastdbd" ] \
    && mv -f "$tmp" "$LAUNCHD_PLIST" \
    || { rm -f -- "$tmp"; return 1; }
  "$current_tool" set --lastdb-home "$PRIMARY_HOME" --bin-dir "$dir" >/dev/null 2>&1
}

# Stage the exact candidate pair into its own program directory.
programs_stage_candidate() {
  local oid="${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" staging
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] \
    || die "the programs venue needs LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID (a full source oid)"
  NEW_PROGRAM_DIR="$PROGRAMS_DIR/$oid"
  [ "$NEW_PROGRAM_DIR" != "$OLD_PROGRAM_DIR" ] \
    || die "the candidate source oid is the running pair"
  if [ -e "$NEW_PROGRAM_DIR" ] || [ -L "$NEW_PROGRAM_DIR" ]; then
    [ -d "$NEW_PROGRAM_DIR" ] && [ ! -L "$NEW_PROGRAM_DIR" ] \
      && sidebin_pair_hashes_match_expected \
        "$NEW_PROGRAM_DIR/lastdbd" "$NEW_PROGRAM_DIR/lastdb" "existing candidate program directory" \
      || die "candidate program directory exists with other bytes: $NEW_PROGRAM_DIR"
    log "candidate program directory already holds the exact pair: $NEW_PROGRAM_DIR"
    return 0
  fi
  staging="$PROGRAMS_DIR/.staging-$oid-$$"
  rm -rf -- "$staging"
  mkdir -m 755 "$staging" || die "cannot create the candidate staging directory"
  cp "$CANDIDATE_BIN" "$staging/lastdbd" && cp "$CANDIDATE_CLI_BIN" "$staging/lastdb" \
    && chmod 755 "$staging/lastdbd" "$staging/lastdb" \
    || { rm -rf -- "$staging"; die "cannot stage the candidate pair"; }
  xattr -c "$staging/lastdbd" "$staging/lastdb" 2>/dev/null || true
  if ! sidebin_pair_hashes_match_expected "$staging/lastdbd" "$staging/lastdb" "staged candidate program pair" \
    || ! codesign --verify --strict "$staging/lastdbd" >/dev/null 2>&1 \
    || ! codesign --verify --strict "$staging/lastdb" >/dev/null 2>&1; then
    rm -rf -- "$staging"
    die "staged candidate program pair is not the exact signed candidate pair; the primary is unchanged"
  fi
  [ ! -e "$NEW_PROGRAM_DIR" ] && mv "$staging" "$NEW_PROGRAM_DIR" \
    || { rm -rf -- "$staging"; die "cannot install the candidate program directory"; }
  log "installed the candidate pair into $NEW_PROGRAM_DIR"
}

live_install_programs() {
  local uid service lock ts stopped_spool
  uid="$(id -u)"
  service="gui/${uid}/${LAUNCHD_LABEL}"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  lock="$PROGRAMS_DIR/.cutover.lock"
  if [ -e "$lock" ]; then
    die "cutover lock present ($lock) — another upgrade in flight? Remove it only after checking"
  fi
  echo "$$ $CAND_VER $ts" >"$lock"
  CUTOVER_LOCK="$lock"

  # The old directory is the rollback pair. Record it before any change.
  SIDEBIN_DIR="$OLD_PROGRAM_DIR"
  SIDEBIN_BACKUP_DAEMON="$OLD_PROGRAM_DIR/lastdbd"
  SIDEBIN_BACKUP_CLI="$OLD_PROGRAM_DIR/lastdb"
  write_cutover_recovery_state "programs-backups-ready" false
  programs_stage_candidate

  # The recovery point comes from the OLD build status. A refusal leaves the
  # primary running and unheld.
  backup_recovery_point_preflight
  [ ! -e "$PROGRAMS_REVIVE_HOLD" ] && [ ! -L "$PROGRAMS_REVIVE_HOLD" ] \
    || die "existing memory guard hold blocks the upgrade"
  programs_hold_revive
  strict_prestop_old_primary "$service" "$OLD_PROGRAM_DIR/lastdbd"
  log "old primary flushed and stopped; saved program pair $OLD_PROGRAM_DIR"
  write_cutover_recovery_state "programs-rollback-ready" true
  sidebin_pair_hashes_match_expected \
    "$NEW_PROGRAM_DIR/lastdbd" "$NEW_PROGRAM_DIR/lastdb" "candidate program pair after the stop" \
    || die "candidate pair changed during the stop"
  verify_old_primary_stopped "$service"
  # The stopped home is the recovery point only when the relay confirmed every
  # write in it. Nothing changed yet: recovery starts the old pair again, and
  # that daemon sends the rest.
  stopped_spool="$(backup_stopped_spool_verdict)"
  [ "$stopped_spool" = ok ] \
    || die "the stopped primary holds writes the relay has not confirmed ($stopped_spool); the old pair is unchanged and starts again; run the upgrade again"
  log "stopped spool: the relay confirmed every write of the stopped home"

  write_cutover_recovery_state "programs-switch-started" true
  PROGRAMS_PLIST_SWITCHED=1
  if ! programs_point_at "$NEW_PROGRAM_DIR"; then
    die "program link switch failed before startup"
  fi
  INSTALLED_DAEMON_BIN="$NEW_PROGRAM_DIR/lastdbd"
  INSTALLED_CLI_BIN="$NEW_PROGRAM_DIR/lastdb"
  write_cutover_recovery_state "signed-programs-starting" true
  if ! lastdb_launchd_reload_job launchctl "gui/${uid}" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"; then
    page_human "safe-upgrade: primary lastdbd job reload failed for ${LAUNCHD_LABEL}. Inspect: launchctl print ${service}. Rollback pair: $OLD_PROGRAM_DIR"
    die "launchd job-definition reload failed; inspect launchctl print ${service}. Rollback: set plist ProgramArguments:0 to $OLD_PROGRAM_DIR/lastdbd, last-stack-lastdb-current set --bin-dir $OLD_PROGRAM_DIR, launchctl bootstrap gui/${uid} ${LAUNCHD_PLIST}"
  fi
  local wait_secs="${LASTDB_CUTOVER_SOCKET_WAIT_SECS:-180}" out="" rc=0
  set +e
  out="$(wait_for_live_unix_socket_health "$PRIMARY_SOCK" "$wait_secs" 2>&1)"
  rc=$?
  set -e
  [ -z "$out" ] || while IFS= read -r line; do [ -n "$line" ] && log "$line"; done <<< "$out"
  if [ "$rc" -ne 0 ]; then
    lastdb_launchd_job_loaded launchctl "$service" \
      && warn "listener/health still missing after ${wait_secs}s but the launchd job is loaded — no second daemon is started"
    die "the candidate did not serve /health within ${wait_secs}s; rollback pair: $OLD_PROGRAM_DIR (plist ProgramArguments:0 and last-stack-lastdb-current set --bin-dir)"
  fi
  programs_release_revive_hold
  NATIVE_STOP_ARMED=0
  rm -f "$lock"
}
