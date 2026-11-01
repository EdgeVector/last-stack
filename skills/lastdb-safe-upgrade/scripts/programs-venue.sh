#!/usr/bin/env bash
# Format 7 V2 route: a primary whose LaunchAgent runs
# $PRIMARY_HOME/native-run-v2-programs/<full oid>/lastdbd with automatic V2
# backup on. Sourced by safe-upgrade-lastdb.sh; uses its globals and log/warn/die.
#
# The install matches the manual switch of 2026-11-01: the candidate pair goes
# into its own program directory, the plist ProgramArguments:0 names it, and
# last-stack-lastdb-current points $PRIMARY_HOME/current and the shims at it.
# The old program directory is never changed, so it is the saved rollback pair.
#
# Automatic V2 backup stays on at every step (Tom, 2026-10-31). The CLI
# `cloud backup-v2 start-stopped` refuses while automatic backup is enabled, so
# this route cannot take a final stopped backup. Instead it requires the mutation
# log head to equal the backed-up frontier immediately before the strict stop,
# and the soak requires the candidate to back up through the stopped cut.

PROGRAMS_DIR=""
OLD_PROGRAM_DIR=""
NEW_PROGRAM_DIR=""
PROGRAMS_REVIVE_HOLD="${LASTDBD_GUARD_REVIVE_HOLD_FILE:-$PRIMARY_HOME/monitoring/lastdbd-revive.hold}"
PROGRAMS_REVIVE_HOLD_OWNED=0
PROGRAMS_PLIST_SWITCHED=0
V2_PRESTOP_HEAD=""
V2_PRESTOP_STREAM=""
V2_PRESTOP_ORDINAL=""
V2_STOPPED_CUT=""
V2_RECOVERY_WAIT_SECS="${LASTDB_V2_RECOVERY_WAIT_SECS:-300}"

# A format 7 home has no status.sync object and reports status.durability.
v2_status_is_format7() {
  jq -e '.ok == true and (.status | has("sync") | not)
    and (.status.durability | type) == "object"' "$1" >/dev/null 2>&1
}

# Echo the old program directory when the plist runs a pair from the programs
# directory of this home. The path must be physical and named by a full oid.
programs_old_dir_from_plist() {
  local prog dir parent name
  prog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD_PLIST" 2>/dev/null)" || return 1
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

# Capture one /api/status and one V2 status into fresh mode-600 files in WORK.
# Args: cli out_status_var out_v2_var. The locals have unique names because
# printf -v must reach the caller's variables. Safe in a $(...) subshell.
v2_capture_pair() {
  local _v2cap_cli="$1" _v2cap_status _v2cap_v2
  _v2cap_status="$(umask 077; mktemp "$WORK/v2-status.XXXXXX")" || return 1
  _v2cap_v2="$(umask 077; mktemp "$WORK/v2-backup.XXXXXX")" || return 1
  curl -fsS --max-time 30 --unix-socket "$PRIMARY_SOCK" \
    -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
    http://x/api/status >"$_v2cap_status" 2>/dev/null || return 1
  "$_v2cap_cli" --data-dir "$PRIMARY_HOME" cloud backup-v2 status --json \
    >"$_v2cap_v2" 2>/dev/null || return 1
  printf -v "$2" '%s' "$_v2cap_status"
  printf -v "$3" '%s' "$_v2cap_v2"
}

# The recovery point for a format 7 V2 primary: the automatic backup covers the
# mutation log head. A busy primary can need one more log interval, so retry
# within LASTDB_V2_RECOVERY_WAIT_SECS. Sets V2_PRESTOP_{HEAD,STREAM,ORDINAL}.
v2_recovery_point_preflight() {
  local cli="$1" status="" v2="" result="" report="" started reason head age stream ordinal
  case "$V2_RECOVERY_WAIT_SECS" in ''|*[!0-9]*) die "LASTDB_V2_RECOVERY_WAIT_SECS must be a whole number" ;; esac
  case "$CLOUD_RECOVERY_MAX_AGE_SECS" in ''|*[!0-9]*) die "LASTDB_CLOUD_RECOVERY_MAX_AGE_SECS must be a whole number" ;; esac
  [ -z "$STALE_RECOVERY_WAIVER" ] \
    || die "the format 7 V2 route takes no stale recovery point waiver; the primary was not stopped"
  started="$(date +%s)"
  while :; do
    v2_capture_pair "$cli" status v2 \
      || die "V2 recovery point: a status sample is unavailable; the primary was not stopped"
    if result="$(python3 "$_SCRIPT_DIR/cloud-recovery-status.py" --status "$status" \
        --v2-status "$v2" --max-age-secs "$CLOUD_RECOVERY_MAX_AGE_SECS" 2>/dev/null)"; then
      break
    fi
    report="$(python3 "$_SCRIPT_DIR/cloud-recovery-status.py" --status "$status" \
      --v2-status "$v2" --max-age-secs "$CLOUD_RECOVERY_MAX_AGE_SECS" --report 2>/dev/null)" \
      || die "V2 recovery status refused (${result:-refused}); the primary was not stopped"
    if [ "$(( $(date +%s) - started ))" -ge "$V2_RECOVERY_WAIT_SECS" ]; then
      die "V2 recovery point is not current after ${V2_RECOVERY_WAIT_SECS}s: ${report#report }; the primary was not stopped"
    fi
    log "V2 recovery point is not current yet: ${report#report }; retry in 15s"
    sleep 15
  done
  read -r reason head age stream ordinal <<< "$result"
  [ "$reason" = ok-v2 ] && [[ "$head" =~ ^[0-9]+/[0-9]+$ ]] \
    && [[ "$stream" =~ ^[0-9a-f-]{36}$ ]] && [[ "$ordinal" =~ ^[0-9]+$ ]] \
    || die "V2 recovery status result is unsupported; the primary was not stopped"
  V2_PRESTOP_HEAD="$head"
  V2_PRESTOP_STREAM="$stream"
  V2_PRESTOP_ORDINAL="$ordinal"
  CLOUD_RECOVERY_FRONTIER="$head"
  log "V2 recovery point: the automatic backup covers the mutation log head $head (stream $stream, accepted ordinal $ordinal, last backup ${age}s ago); writes after this sample wait for the candidate's first log backup"
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
  local dir="$1" tmp current_tool="$_SCRIPT_DIR/../../../bin/last-stack-lastdb-current"
  [ -x "$current_tool" ] || current_tool="$(command -v last-stack-lastdb-current)" || return 1
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

# Return the plist and current link to the old pair. The old directory never
# changed, so its hashes still match the recorded rollback pair.
programs_restore_old_pair() {
  [ -n "$OLD_PROGRAM_DIR" ] || return 1
  programs_point_at "$OLD_PROGRAM_DIR" || return 1
  PROGRAMS_PLIST_SWITCHED=0
  log "restored the plist and current link to the old pair $OLD_PROGRAM_DIR"
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
    die "staged candidate program pair is not the photographed signed pair; the primary is unchanged"
  fi
  [ ! -e "$NEW_PROGRAM_DIR" ] && mv "$staging" "$NEW_PROGRAM_DIR" \
    || { rm -rf -- "$staging"; die "cannot install the candidate program directory"; }
  log "installed the candidate pair into $NEW_PROGRAM_DIR"
}

live_install_programs() {
  local uid service lock ts
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

  ensure_primary_launchd_rss_limit
  ensure_primary_launchd_warm_cache_limit
  ensure_primary_launchd_exit_timeout
  programs_hold_revive
  v2_recovery_point_preflight "$OLD_PROGRAM_DIR/lastdb"
  strict_prestop_old_primary "$service" "$OLD_PROGRAM_DIR/lastdbd"
  log "recovery point (no copy of the primary): automatic V2 backup through $V2_PRESTOP_HEAD (stream $V2_PRESTOP_STREAM, ordinal $V2_PRESTOP_ORDINAL); saved program pair $OLD_PROGRAM_DIR"
  write_cutover_recovery_state "programs-rollback-ready" true
  sidebin_pair_hashes_match_expected \
    "$NEW_PROGRAM_DIR/lastdbd" "$NEW_PROGRAM_DIR/lastdb" "candidate program pair after the stop" \
    || die "candidate pair changed during the stop"
  verify_old_primary_stopped "$service"

  write_cutover_recovery_state "programs-switch-started" true
  PROGRAMS_PLIST_SWITCHED=1
  if ! programs_point_at "$NEW_PROGRAM_DIR"; then
    programs_restore_old_pair \
      && lastdb_launchd_reload_job launchctl "gui/${uid}" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST" \
      && wait_for_live_unix_socket_health "$PRIMARY_SOCK" 180 >/dev/null 2>&1 \
      || page_human "safe-upgrade: the program switch failed and the old pair did not come back. Plist ProgramArguments:0 must be $OLD_PROGRAM_DIR/lastdbd; then launchctl bootstrap gui/${uid} ${LAUNCHD_PLIST}"
    die "could not point the plist and current link at the candidate; restarted the old pair"
  fi
  INSTALLED_DAEMON_BIN="$NEW_PROGRAM_DIR/lastdbd"
  INSTALLED_CLI_BIN="$NEW_PROGRAM_DIR/lastdb"
  write_cutover_recovery_state "programs-reload-started" true
  if ! lastdb_launchd_reload_job launchctl "gui/${uid}" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"; then
    page_human "safe-upgrade: primary lastdbd job reload failed for ${LAUNCHD_LABEL}. Inspect: launchctl print ${service}. Rollback pair: $OLD_PROGRAM_DIR"
    die "launchd job-definition reload failed; inspect launchctl print ${service}. Rollback: set plist ProgramArguments:0 to $OLD_PROGRAM_DIR/lastdbd, last-stack-lastdb-current set --bin-dir $OLD_PROGRAM_DIR, launchctl bootstrap gui/${uid} ${LAUNCHD_PLIST}"
  fi
  RESTART_INTENT_START_REQUESTED=1
  write_cutover_recovery_state "programs-supervisor-loaded" true
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
  rm -f "$lock"
}

# Read the first candidate V2 status after the start. Its log head is the
# stopped cut plus any early writes; the soak needs a backup through it.
v2_record_stopped_cut() {
  local status="" v2="" waited=0
  while [ "$waited" -le 120 ]; do
    if v2_capture_pair "$NEW_PROGRAM_DIR/lastdb" status v2 \
      && V2_STOPPED_CUT="$(jq -er '.mutation_log.head.frontiers
          | select((.main | type) == "number" and (.cas | type) == "number")
          | "\(.main)/\(.cas)"' "$v2")"; then
      log "candidate V2 log head after start: $V2_STOPPED_CUT (pre-stop backed head $V2_PRESTOP_HEAD)"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  die "the candidate V2 status did not report a mutation log head; recovery = the old program pair $OLD_PROGRAM_DIR and the cloud backup"
}

programs_rollback_text() {
  echo "  /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 $OLD_PROGRAM_DIR/lastdbd' $LAUNCHD_PLIST"
  echo "  last-stack-lastdb-current set --lastdb-home $PRIMARY_HOME --bin-dir $OLD_PROGRAM_DIR"
  echo "  # stop the candidate with the strict stop in SKILL.md, then:"
  echo "  launchctl bootstrap gui/\$(id -u) $LAUNCHD_PLIST"
}
