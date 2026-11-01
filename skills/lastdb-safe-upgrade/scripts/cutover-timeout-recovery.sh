#!/usr/bin/env bash
# Recover a sidebin or programs primary after the bounded CUTOVER driver stops.
# programs venue: the old pair stays unchanged in its own
# native-run-v2-programs/<oid> directory; recovery points the plist and the
# current link back at it and reloads the job.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=launchd-job-checks.sh
. "$SCRIPT_DIR/launchd-job-checks.sh"
# shellcheck source=live-socket-health.sh
. "$SCRIPT_DIR/live-socket-health.sh"

STATE=""
EXPECTED_EXEC_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE="${2:-}"; shift 2 ;;
    --loom-exec-id) EXPECTED_EXEC_ID="${2:-}"; shift 2 ;;
    *) printf 'CUTOVER_TIMEOUT_RECOVERY=red reason=unknown-argument\n' >&2; exit 2 ;;
  esac
done

recovery_die() {
  printf 'CUTOVER_TIMEOUT_RECOVERY=red reason=%s\n' "$1" >&2
  exit 1
}

portable_uid() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

portable_mode() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

json_string() {
  jq -er --arg key "$2" '.[$key] | select(type == "string")' "$1"
}

[ -n "$STATE" ] || recovery_die "state-path-absent"
[ -n "$EXPECTED_EXEC_ID" ] || recovery_die "loom-exec-id-absent"
case "$STATE" in /*) ;; *) recovery_die "state-path-not-absolute" ;; esac

RECOVERY_ROOT="${LASTDB_CUTOVER_RECOVERY_ROOT:-$HOME/.local/state/last-stack/lastdb-safe-upgrade/cutover-recovery}"
case "$RECOVERY_ROOT" in /*) ;; *) recovery_die "recovery-root-not-absolute" ;; esac
[ -d "$RECOVERY_ROOT" ] && [ ! -L "$RECOVERY_ROOT" ] \
  || recovery_die "recovery-root-unsafe"
root_real="$(CDPATH= cd -- "$RECOVERY_ROOT" && pwd -P)"
[ "$root_real" = "$RECOVERY_ROOT" ] || recovery_die "recovery-root-not-canonical"
[ "$(portable_uid "$RECOVERY_ROOT")" = "$(id -u)" ] \
  || recovery_die "recovery-root-wrong-owner"
[ "$(portable_mode "$RECOVERY_ROOT")" = 700 ] \
  || recovery_die "recovery-root-wrong-mode"
[ "$(dirname -- "$STATE")" = "$RECOVERY_ROOT" ] \
  || recovery_die "state-outside-recovery-root"
[ -f "$STATE" ] && [ ! -L "$STATE" ] || recovery_die "state-file-unsafe"
[ "$(portable_uid "$STATE")" = "$(id -u)" ] \
  || recovery_die "state-file-wrong-owner"
[ "$(portable_mode "$STATE")" = 600 ] \
  || recovery_die "state-file-wrong-mode"

jq -e '
  (keys | sort) == ([
    "backup_lastdb", "backup_lastdb_sha256", "backup_lastdbd",
    "backup_lastdbd_sha256", "effect_started", "launchd_label",
    "launchd_plist", "loom_execution_id", "primary_home",
    "primary_socket", "old_pid", "old_start_ts", "old_ps_lstart",
    "sidebin_dir", "stage", "state_version", "venue"
  ] | sort)
  and .state_version == 3
  and (.effect_started | type) == "boolean"
' "$STATE" >/dev/null || recovery_die "state-schema-invalid"

state_exec_id="$(json_string "$STATE" loom_execution_id)" \
  || recovery_die "state-exec-id-invalid"
[ "$state_exec_id" = "$EXPECTED_EXEC_ID" ] \
  || recovery_die "state-exec-id-mismatch"
stage="$(json_string "$STATE" stage)" || recovery_die "state-stage-invalid"
effect_started="$(jq -r '.effect_started' "$STATE")"

if [ "$effect_started" != true ]; then
  printf 'CUTOVER_TIMEOUT_RECOVERY=not-required stage=%s effect_started=false\n' "$stage"
  exit 0
fi

venue="$(json_string "$STATE" venue)" || recovery_die "state-venue-invalid"
case "$venue" in sidebin|programs) ;; *) recovery_die "unsupported-live-venue" ;; esac
primary_home="$(json_string "$STATE" primary_home)" \
  || recovery_die "state-primary-home-invalid"
primary_socket="$(json_string "$STATE" primary_socket)" \
  || recovery_die "state-primary-socket-invalid"
old_pid="$(json_string "$STATE" old_pid)" \
  || recovery_die "state-old-pid-invalid"
case "$old_pid" in ''|*[!0-9]*) recovery_die "state-old-pid-invalid" ;; esac
[ "$old_pid" -gt 0 ] || recovery_die "state-old-pid-invalid"
old_start_ts="$(json_string "$STATE" old_start_ts)" \
  || recovery_die "state-old-start-ts-invalid"
case "$old_start_ts" in ''|*[!0-9]*) recovery_die "state-old-start-ts-invalid" ;; esac
[ "$old_start_ts" -gt 0 ] || recovery_die "state-old-start-ts-invalid"
old_ps_lstart="$(json_string "$STATE" old_ps_lstart)" \
  || recovery_die "state-old-process-start-invalid"
[ -n "$old_ps_lstart" ] || recovery_die "state-old-process-start-invalid"
sidebin_dir="$(json_string "$STATE" sidebin_dir)" \
  || recovery_die "state-sidebin-dir-invalid"
launchd_label="$(json_string "$STATE" launchd_label)" \
  || recovery_die "state-launchd-label-invalid"
launchd_plist="$(json_string "$STATE" launchd_plist)" \
  || recovery_die "state-launchd-plist-invalid"
backup_daemon="$(json_string "$STATE" backup_lastdbd)" \
  || recovery_die "state-daemon-backup-invalid"
backup_cli="$(json_string "$STATE" backup_lastdb)" \
  || recovery_die "state-cli-backup-invalid"
backup_daemon_sha="$(json_string "$STATE" backup_lastdbd_sha256)" \
  || recovery_die "state-daemon-hash-invalid"
backup_cli_sha="$(json_string "$STATE" backup_lastdb_sha256)" \
  || recovery_die "state-cli-hash-invalid"

for path in "$primary_home" "$primary_socket" "$sidebin_dir" \
  "$launchd_plist" "$backup_daemon" "$backup_cli"; do
  case "$path" in /*) ;; *) recovery_die "state-path-not-absolute" ;; esac
done
[ -d "$primary_home" ] && [ ! -L "$primary_home" ] \
  || recovery_die "primary-home-unsafe"
[ -d "$sidebin_dir" ] && [ ! -L "$sidebin_dir" ] \
  || recovery_die "sidebin-dir-unsafe"
[ "$(CDPATH= cd -- "$sidebin_dir" && pwd -P)" = "$sidebin_dir" ] \
  || recovery_die "sidebin-dir-not-canonical"
[ -f "$launchd_plist" ] && [ ! -L "$launchd_plist" ] \
  || recovery_die "launchd-plist-unsafe"
case "$launchd_label" in
  ''|com.REPLACE.*|*[!A-Za-z0-9._-]*) recovery_die "launchd-label-invalid" ;;
esac
[ "$(dirname -- "$backup_daemon")" = "$sidebin_dir" ] \
  && [ "$(dirname -- "$backup_cli")" = "$sidebin_dir" ] \
  || recovery_die "backup-outside-sidebin-dir"

launchctl_bin="${LASTDB_CUTOVER_RECOVERY_LAUNCHCTL_BIN:-launchctl}"
command -v "$launchctl_bin" >/dev/null 2>&1 \
  || recovery_die "launchctl-absent"
uid="$(id -u)"
domain="gui/$uid"
service="$domain/$launchd_label"

if [ "$venue" = programs ]; then
  # The old pair is the unchanged program directory itself.
  [[ "$(basename -- "$sidebin_dir")" =~ ^[0-9a-f]{40}$ ]] \
    || recovery_die "programs-dir-name-invalid"
  [ "$(dirname -- "$sidebin_dir")" = "$primary_home/native-run-v2-programs" ] \
    || recovery_die "programs-dir-outside-home"
  [ "$backup_daemon" = "$sidebin_dir/lastdbd" ] && [ "$backup_cli" = "$sidebin_dir/lastdb" ] \
    || recovery_die "programs-pair-path-invalid"
  case "$backup_daemon_sha$backup_cli_sha" in *[!0-9a-f]*|'') recovery_die "backup-pair-hash-invalid" ;; esac
  hold="$sidebin_dir/lastdbd.prestop-hold"
  if [ -e "$hold" ] || [ -L "$hold" ]; then
    # An interrupted strict stop leaves the old program at its hold path.
    [ -f "$hold" ] && [ ! -L "$hold" ] && [ "$(sha256_file "$hold")" = "$backup_daemon_sha" ] \
      || recovery_die "prestop-hold-not-old-daemon"
    if [ -e "$backup_daemon" ] || [ -L "$backup_daemon" ]; then
      rm -f -- "$hold" || recovery_die "prestop-hold-remove-failed"
    else
      mv -f -- "$hold" "$backup_daemon" || recovery_die "prestop-hold-restore-failed"
    fi
  fi
  [ -f "$backup_daemon" ] && [ ! -L "$backup_daemon" ] && [ -x "$backup_daemon" ] \
    && [ -f "$backup_cli" ] && [ ! -L "$backup_cli" ] && [ -x "$backup_cli" ] \
    || recovery_die "programs-pair-unsafe"
  [ "$(sha256_file "$backup_daemon")" = "$backup_daemon_sha" ] \
    && [ "$(sha256_file "$backup_cli")" = "$backup_cli_sha" ] \
    || recovery_die "backup-pair-hash-mismatch"
  current_program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launchd_plist" 2>/dev/null)" \
    || recovery_die "launchd-plist-program-unreadable"
  case "$stage" in
    programs-stop-started|programs-stopped|programs-rollback-ready)
      [ "$current_program" = "$backup_daemon" ] || recovery_die "plist-changed-before-switch" ;;
    programs-switch-started|programs-reload-started|programs-supervisor-loaded) ;;
    *) recovery_die "unsupported-programs-stage" ;;
  esac
  if [ "$current_program" != "$backup_daemon" ]; then
    plist_tmp="$(dirname -- "$launchd_plist")/.$(basename -- "$launchd_plist").recovery.$$"
    rm -f -- "$plist_tmp"
    cp -p "$launchd_plist" "$plist_tmp" \
      && /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $backup_daemon" "$plist_tmp" >/dev/null \
      && plutil -lint "$plist_tmp" >/dev/null \
      && mv -f "$plist_tmp" "$launchd_plist" \
      || { rm -f -- "$plist_tmp"; recovery_die "plist-restore-failed"; }
  fi
  current_tool="$SCRIPT_DIR/../../../bin/last-stack-lastdb-current"
  [ -x "$current_tool" ] || current_tool="$(command -v last-stack-lastdb-current)" \
    || recovery_die "current-link-tool-absent"
  "$current_tool" set --lastdb-home "$primary_home" --bin-dir "$sidebin_dir" >/dev/null 2>&1 \
    || recovery_die "current-link-restore-failed"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launchd_plist" 2>/dev/null)" = "$backup_daemon" ] \
    || recovery_die "plist-restore-unverified"
fi

if [ "$venue" = sidebin ]; then
daemon_base="$(basename -- "$backup_daemon")"
cli_base="$(basename -- "$backup_cli")"
case "$daemon_base" in lastdbd.bak-pre-*) ;; *) recovery_die "daemon-backup-name-invalid" ;; esac
case "$cli_base" in lastdb.bak-pre-*) ;; *) recovery_die "cli-backup-name-invalid" ;; esac
[ "${daemon_base#lastdbd.}" = "${cli_base#lastdb.}" ] \
  || recovery_die "backup-pair-suffix-mismatch"
[ -f "$backup_daemon" ] && [ ! -L "$backup_daemon" ] && [ -x "$backup_daemon" ] \
  || recovery_die "daemon-backup-unsafe"
[ -f "$backup_cli" ] && [ ! -L "$backup_cli" ] && [ -x "$backup_cli" ] \
  || recovery_die "cli-backup-unsafe"
[ "$(portable_uid "$backup_daemon")" = "$(id -u)" ] \
  && [ "$(portable_uid "$backup_cli")" = "$(id -u)" ] \
  || recovery_die "backup-pair-wrong-owner"
case "$backup_daemon_sha" in *[!0-9a-f]*|'') recovery_die "daemon-backup-hash-invalid" ;; esac
case "$backup_cli_sha" in *[!0-9a-f]*|'') recovery_die "cli-backup-hash-invalid" ;; esac
[ "${#backup_daemon_sha}" -eq 64 ] && [ "${#backup_cli_sha}" -eq 64 ] \
  || recovery_die "backup-pair-hash-length-invalid"
[ "$(sha256_file "$backup_daemon")" = "$backup_daemon_sha" ] \
  && [ "$(sha256_file "$backup_cli")" = "$backup_cli_sha" ] \
  || recovery_die "backup-pair-hash-mismatch"

daemon_tmp="$sidebin_dir/.lastdbd.timeout-recovery.$$"
cli_tmp="$sidebin_dir/.lastdb.timeout-recovery.$$"
cleanup_restore_tmp() {
  rm -f -- "$daemon_tmp" "$cli_tmp"
}
on_recovery_signal() {
  trap - HUP INT TERM
  cleanup_restore_tmp
  exit 143
}
trap cleanup_restore_tmp EXIT
trap on_recovery_signal HUP INT TERM
rm -f -- "$daemon_tmp" "$cli_tmp"
cp -a "$backup_daemon" "$daemon_tmp" || recovery_die "daemon-restore-copy-failed"
cp -a "$backup_cli" "$cli_tmp" || recovery_die "cli-restore-copy-failed"
[ "$(sha256_file "$daemon_tmp")" = "$backup_daemon_sha" ] \
  && [ "$(sha256_file "$cli_tmp")" = "$backup_cli_sha" ] \
  || recovery_die "staged-restore-hash-mismatch"
cmp -s "$backup_daemon" "$daemon_tmp" && cmp -s "$backup_cli" "$cli_tmp" \
  || recovery_die "staged-restore-byte-mismatch"

codesign_bin="${LASTDB_CUTOVER_RECOVERY_CODESIGN_BIN:-codesign}"
xattr_bin="${LASTDB_CUTOVER_RECOVERY_XATTR_BIN:-xattr}"
command -v "$codesign_bin" >/dev/null 2>&1 \
  || recovery_die "codesign-absent"
command -v "$xattr_bin" >/dev/null 2>&1 \
  || recovery_die "xattr-absent"
"$codesign_bin" --force --sign - "$daemon_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-daemon-resign-failed"
"$codesign_bin" --force --sign - "$cli_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-cli-resign-failed"
"$xattr_bin" -c "$daemon_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-daemon-quarantine-clear-failed"
"$xattr_bin" -c "$cli_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-cli-quarantine-clear-failed"
"$codesign_bin" --verify --strict "$daemon_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-daemon-signature-invalid"
"$codesign_bin" --verify --strict "$cli_tmp" >/dev/null 2>&1 \
  || recovery_die "staged-cli-signature-invalid"

backup_daemon_version="$("$backup_daemon" --version 2>/dev/null | awk '{print $NF}')"
backup_cli_version="$("$backup_cli" --version 2>/dev/null | awk '{print $NF}')"
staged_daemon_version="$("$daemon_tmp" --version 2>/dev/null | awk '{print $NF}')"
staged_cli_version="$("$cli_tmp" --version 2>/dev/null | awk '{print $NF}')"
[ -n "$backup_daemon_version" ] && [ "$backup_daemon_version" = "$backup_cli_version" ] \
  || recovery_die "backup-pair-version-mismatch"
[ "$staged_daemon_version" = "$backup_daemon_version" ] \
  && [ "$staged_cli_version" = "$backup_cli_version" ] \
  || recovery_die "staged-restore-exec-or-version-failed"
restored_daemon_sha="$(sha256_file "$daemon_tmp")"
restored_cli_sha="$(sha256_file "$cli_tmp")"
mv -f "$daemon_tmp" "$sidebin_dir/lastdbd" \
  || recovery_die "daemon-restore-rename-failed"
mv -f "$cli_tmp" "$sidebin_dir/lastdb" \
  || recovery_die "cli-restore-rename-failed"
[ "$(sha256_file "$sidebin_dir/lastdbd")" = "$restored_daemon_sha" ] \
  && [ "$(sha256_file "$sidebin_dir/lastdb")" = "$restored_cli_sha" ] \
  || recovery_die "installed-rollback-hash-mismatch"
installed_daemon_version="$("$sidebin_dir/lastdbd" --version 2>/dev/null | awk '{print $NF}')"
installed_cli_version="$("$sidebin_dir/lastdb" --version 2>/dev/null | awk '{print $NF}')"
[ "$installed_daemon_version" = "$backup_daemon_version" ] \
  && [ "$installed_cli_version" = "$backup_cli_version" ] \
  || recovery_die "installed-rollback-version-mismatch"
hold="$sidebin_dir/lastdbd.prestop-hold"
if [ -e "$hold" ] || [ -L "$hold" ]; then
  [ -f "$hold" ] && [ ! -L "$hold" ] \
    && [ "$(sha256_file "$hold")" = "$backup_daemon_sha" ] \
    || recovery_die "prestop-hold-not-old-daemon"
  rm -f -- "$hold" || recovery_die "prestop-hold-remove-failed"
fi
fi

same_old_process() {
  local observed=""
  kill -0 "$old_pid" 2>/dev/null || return 1
  observed="$(ps -p "$old_pid" -o lstart= 2>/dev/null)" \
    || recovery_die "old-process-start-unreadable-no-reload"
  [ -n "$observed" ] || recovery_die "old-process-start-absent-no-reload"
  [ "$observed" = "$old_ps_lstart" ]
}

# The driver's memory guard revive hold for the programs venue.
release_programs_revive_hold() {
  local revive="${LASTDBD_GUARD_REVIVE_HOLD_FILE:-$primary_home/monitoring/lastdbd-revive.hold}"
  [ "$venue" = programs ] || return 0
  if [ -f "$revive" ] && [ ! -L "$revive" ] \
    && grep -q '^lastdb-safe-upgrade pid=[0-9]*$' "$revive" 2>/dev/null; then
    rm -f -- "$revive"
  fi
}

wait_for_exact_old_exit() {
  local waited=0 limit="${LASTDB_CUTOVER_RECOVERY_OLD_EXIT_WAIT_SECS:-330}"
  local session="$primary_home/current-session.json"
  case "$limit" in ''|*[!0-9]*) recovery_die "old-exit-wait-invalid" ;; esac
  [ "$limit" -ge 300 ] && [ "$limit" -le 360 ] \
    || recovery_die "old-exit-wait-outside-300-to-360-seconds"
  while same_old_process; do
    if [ -e "$session" ] || [ -L "$session" ]; then
      [ -f "$session" ] && [ ! -L "$session" ] \
        || recovery_die "old-session-marker-unsafe-during-drain"
      jq -e --argjson pid "$old_pid" --argjson start_ts "$old_start_ts" \
        '.pid == $pid and .start_ts == $start_ts' "$session" >/dev/null \
        || recovery_die "old-session-identity-changed-during-drain"
    fi
    if [ "$waited" -ge "$limit" ]; then
      recovery_die "old-primary-still-draining pid=$old_pid start_ts=$old_start_ts waited_s=$waited"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'CUTOVER_TIMEOUT_RECOVERY=old-exit-confirmed pid=%s start_ts=%s waited_s=%s\n' \
    "$old_pid" "$old_start_ts" "$waited"
}
case "$stage" in
  sidebin-stop-started|sidebin-stopped|sidebin-rollback-copy-started|sidebin-rollback-ready|\
  programs-stop-started|programs-stopped|programs-rollback-ready)
    # The candidate did not replace the old pair. A failed strict stop may
    # leave the old daemon in its flush drain. Wait for the exact saved
    # process identity to exit; never bootout or kill it.
    wait_for_exact_old_exit
    if lastdb_launchd_job_loaded "$launchctl_bin" "$service"; then
      # A loaded job with no process can remain idle after the interrupted
      # stop. A plain kickstart starts it without killing a process. Never
      # use kickstart -k, and never kickstart while any job PID exists.
      live_pid="$(lastdb_launchd_job_pid "$launchctl_bin" "$service")"
      if [ -z "$live_pid" ]; then
        if live_unix_socket_has_listener "$primary_socket"; then
          recovery_die "unexpected-listener-before-old-kickstart"
        fi
        if ! "$launchctl_bin" kickstart "$service"; then
          printf 'CUTOVER_TIMEOUT_RECOVERY=warn reason=old-primary-kickstart-error-checking-health\n' >&2
        fi
      fi
      wait_for_live_unix_socket_health "$primary_socket" 45 \
        || recovery_die "old-primary-loaded-but-unhealthy-no-reload"
      live_pid="$(live_unix_socket_health_pid "$primary_socket" || true)"
      [ -n "$live_pid" ] \
        && lastdb_require_supervised_primary "$launchctl_bin" "$service" "$live_pid" \
        || recovery_die "old-primary-not-supervised"
      release_programs_revive_hold
      printf 'CUTOVER_TIMEOUT_RECOVERY=green stage=%s rollback=old-primary-serving service=%s pid=%s\n' \
        "$stage" "$service" "$live_pid"
      exit 0
    fi
    if live_unix_socket_has_listener "$primary_socket"; then
      recovery_die "unexpected-listener-before-old-bootstrap"
    fi
    ;;
esac
lastdb_launchd_reload_job "$launchctl_bin" "$domain" "$launchd_label" "$launchd_plist" \
  || recovery_die "launchd-reload-failed"

health_wait="${LASTDB_CUTOVER_RECOVERY_HEALTH_WAIT_SECS:-45}"
case "$health_wait" in ''|*[!0-9]*) recovery_die "health-wait-invalid" ;; esac
[ "$health_wait" -gt 0 ] || recovery_die "health-wait-invalid"
wait_for_live_unix_socket_health "$primary_socket" "$health_wait" \
  || recovery_die "primary-health-failed"
live_pid="$(live_unix_socket_health_pid "$primary_socket" || true)"
[ -n "$live_pid" ] || recovery_die "primary-listener-pid-absent"
lastdb_require_supervised_primary "$launchctl_bin" "$service" "$live_pid" \
  || recovery_die "primary-not-supervised"

release_programs_revive_hold

printf 'CUTOVER_TIMEOUT_RECOVERY=green stage=%s rollback=restored service=%s pid=%s\n' \
  "$stage" "$service" "$live_pid"
