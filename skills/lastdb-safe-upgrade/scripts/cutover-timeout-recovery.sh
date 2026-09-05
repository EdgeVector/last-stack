#!/usr/bin/env bash
# Recover a sidebin primary after the bounded CUTOVER driver stops.
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
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

portable_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
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
    "primary_socket", "sidebin_dir", "stage", "state_version", "venue"
  ] | sort)
  and .state_version == 1
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
[ "$venue" = sidebin ] || recovery_die "unsupported-live-venue"
primary_home="$(json_string "$STATE" primary_home)" \
  || recovery_die "state-primary-home-invalid"
primary_socket="$(json_string "$STATE" primary_socket)" \
  || recovery_die "state-primary-socket-invalid"
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

launchctl_bin="${LASTDB_CUTOVER_RECOVERY_LAUNCHCTL_BIN:-launchctl}"
command -v "$launchctl_bin" >/dev/null 2>&1 \
  || recovery_die "launchctl-absent"
uid="$(id -u)"
domain="gui/$uid"
service="$domain/$launchd_label"
lastdb_launchd_reload_job "$launchctl_bin" "$domain" "$launchd_label" "$launchd_plist" \
  || recovery_die "launchd-reload-failed"

health_wait="${LASTDB_CUTOVER_RECOVERY_HEALTH_WAIT_SECS:-45}"
case "$health_wait" in ''|*[!0-9]*) recovery_die "health-wait-invalid" ;; esac
[ "$health_wait" -gt 0 ] || recovery_die "health-wait-invalid"
wait_for_live_unix_socket_health "$primary_socket" "$health_wait" \
  || recovery_die "primary-health-failed"
live_pid="$(live_unix_socket_listener_pid "$primary_socket" || true)"
[ -n "$live_pid" ] || recovery_die "primary-listener-pid-absent"
lastdb_require_supervised_primary "$launchctl_bin" "$service" "$live_pid" \
  || recovery_die "primary-not-supervised"

printf 'CUTOVER_TIMEOUT_RECOVERY=green stage=%s rollback=restored service=%s pid=%s\n' \
  "$stage" "$service" "$live_pid"
