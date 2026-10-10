#!/usr/bin/env bash
# Remove one retained trial or incomplete stopped copy after primary recovery.
# The default checks only. This helper never removes a published rollback point.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=owner-lock.sh
. "$SCRIPT_DIR/owner-lock.sh"
# shellcheck source=launchd-job-checks.sh
. "$SCRIPT_DIR/launchd-job-checks.sh"
# shellcheck source=live-socket-health.sh
. "$SCRIPT_DIR/live-socket-health.sh"

usage() {
  cat <<'EOF'
Usage: cleanup-retained-upgrade-copy.sh --copy ABSOLUTE_PATH \
  --expect-primary-pid PID --expect-primary-start-ts START_TS \
  --launchd-label LABEL [--execute]

The default checks one retained trial or .incomplete stopped copy. --execute
removes it after a healthy supervised primary check. The command stops after
600 seconds and can leave a partial copy. Run the same command again then.
EOF
}

die() { printf 'RETAINED_COPY_CLEANUP=red reason=%s\n' "$1" >&2; exit 1; }

copy=""
expected_pid=""
expected_start_ts=""
label=""
execute=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --copy|--expect-primary-pid|--expect-primary-start-ts|--launchd-label)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --copy) copy="$2" ;;
        --expect-primary-pid) expected_pid="$2" ;;
        --expect-primary-start-ts) expected_start_ts="$2" ;;
        --launchd-label) label="$2" ;;
      esac
      shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$copy" in /*) ;; *) die copy-path-not-absolute ;; esac
case "$expected_pid" in ''|*[!0-9]*) die expected-primary-pid-invalid ;; esac
case "$expected_start_ts" in ''|*[!0-9]*) die expected-primary-start-ts-invalid ;; esac
case "$label" in ''|com.REPLACE.*|*[!A-Za-z0-9._-]*) die launchd-label-invalid ;; esac
[ "$expected_pid" -gt 0 ] && [ "$expected_start_ts" -gt 0 ] \
  || die expected-primary-identity-invalid

uid="$(id -u)"
[ "$(uname -s)" = Darwin ] || die cleanup-requires-macos
home="${LASTDB_HOME:-$HOME/.lastdb}"
sock="$home/data/folddb.sock"
default_tmp="${TMPDIR:-/tmp}"
home_real="$(CDPATH= cd -- "$HOME" && pwd -P)"
case "$(CDPATH= cd -- "$default_tmp" 2>/dev/null && pwd -P || printf '%s' "$default_tmp")" in
  "$home_real"|"$home_real"/*) default_tmp=/tmp ;;
esac
root="${LASTDB_ROLLBACK_ROOT:-${LASTDB_BACKUP_ROOT:-$default_tmp/lastdb-safe-upgrade-rollback-$uid}}"
owner_lock="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR:-/tmp/lastdb-safe-upgrade-owner-$uid.lock.d}"

token="$$.$RANDOM.$(date +%s)"
held=0
release_lock() {
  safe_upgrade_owner_lock_release "$owner_lock" "$token" "$held" \
    || printf 'WARN: owner lock release failed: %s\n' "$owner_lock" >&2
}
trap release_lock EXIT
LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=0 \
  safe_upgrade_owner_lock_acquire_wait "$owner_lock" "$token" "$$" "$copy" "retained-copy-cleanup" \
  || die safe-upgrade-owner-active
held=1

[ -d "$root" ] && [ ! -L "$root" ] || die rollback-root-unsafe
root_real="$(CDPATH= cd -- "$root" && pwd -P)"
[ "$(basename -- "$root_real")" = "lastdb-safe-upgrade-rollback-$uid" ] \
  || die rollback-root-name-invalid
case "$root_real" in
  "$home_real"|"$home_real"/*) die rollback-root-under-home ;;
  /private/tmp/*|/private/var/folders/*/T/*) ;;
  *) die rollback-root-outside-temporary-directory ;;
esac
[ "$(stat -f '%u' "$root_real")" = "$uid" ] || die rollback-root-owner-invalid
[ -d "$copy" ] && [ ! -L "$copy" ] || die copy-unsafe
copy_real="$(CDPATH= cd -- "$copy" && pwd -P)"
base="$(basename -- "$copy_real")"
[ "$copy_real" = "$root_real/$base" ] || die copy-not-direct-child
[ "$(stat -f '%u' "$copy_real")" = "$uid" ] || die copy-owner-invalid
[ "$(stat -f '%d' "$copy_real")" = "$(stat -f '%d' "$root_real")" ] \
  || die copy-crosses-volume
case "$base" in
  trial-*-from-*)
    [[ "$base" =~ ^trial-.+-from-.+-[0-9]{8}T[0-9]{6}Z$ ]] \
      || die trial-name-invalid
    if [ -e "$copy_real/.safe-upgrade/complete" ] \
        || [ -L "$copy_real/.safe-upgrade/complete" ]; then
      [ -f "$copy_real/.safe-upgrade/complete" ] \
        && [ ! -L "$copy_real/.safe-upgrade/complete" ] \
        && grep -qx 'kind=trial' "$copy_real/.safe-upgrade/complete" \
        || die trial-marker-invalid
    fi
    ;;
  pre-*-from-*.incomplete)
    [[ "$base" =~ ^pre-.+-from-.+-[0-9]{8}T[0-9]{6}Z\.incomplete$ ]] \
      || die incomplete-name-invalid
    ;;
  *) die published-rollback-or-unrelated-copy ;;
esac
[ "$copy_real" != "$home_real" ] || die copy-is-primary
if [ -d "$copy_real/data" ]; then
  [ ! -L "$copy_real/data" ] || die copy-data-symlink
  [ "$(CDPATH= cd -- "$copy_real/data" && pwd -P)" != \
      "$(CDPATH= cd -- "$home/data" && pwd -P)" ] || die copy-data-aliases-primary
fi

check_primary_and_copy() {
  local service="gui/$uid/$label" job_pid health_pid session command_line processes pid executable
  local logical_copy logical_real copy_path
  job_pid="$(lastdb_launchd_job_pid launchctl "$service")"
  health_pid="$(live_unix_socket_health_pid "$sock" || true)"
  [ "$job_pid" = "$expected_pid" ] && [ "$health_pid" = "$expected_pid" ] \
    && lastdb_require_supervised_primary launchctl "$service" "$health_pid" >/dev/null \
    || die primary-not-supervised-and-healthy
  session="$home/current-session.json"
  [ -f "$session" ] && [ ! -L "$session" ] \
    && jq -e --argjson pid "$expected_pid" --argjson start_ts "$expected_start_ts" \
      '.pid == $pid and .start_ts == $start_ts' "$session" >/dev/null \
    || die primary-session-changed
  [ -d "$copy_real" ] && [ ! -L "$copy_real" ] \
    && [ "$(stat -f '%u' "$copy_real")" = "$uid" ] \
    && [ "$(CDPATH= cd -- "$copy_real" && pwd -P)" = "$root_real/$base" ] \
    || die copy-changed
  logical_copy=""
  case "$copy_real" in
    /private/var/*|/private/tmp/*)
      logical_copy="${copy_real#/private}"
      [ -d "$logical_copy" ] && [ ! -L "$logical_copy" ] \
        && logical_real="$(CDPATH='' cd -- "$logical_copy" && pwd -P)" \
        && [ "$logical_real" = "$copy_real" ] \
        || die copy-logical-alias-unverified
      ;;
  esac
  if live_unix_socket_has_listener "$copy_real/data/folddb.sock" \
      || live_unix_socket_has_listener "$copy_real/data/folddb-full.sock"; then
    die copy-has-live-listener
  fi
  # comm identifies the executable, so a helper's launchd label cannot make
  # that helper a lastdbd process. Read arguments only for actual daemons.
  processes="$(ps -ww -axo pid=,comm=)" || die active-process-list-unavailable
  while read -r pid executable; do
    case "$pid" in ''|*[!0-9]*) die active-process-list-invalid ;; esac
    [ "${executable##*/}" = lastdbd ] || continue
    command_line="$(ps -ww -p "$pid" -o args=)" \
      || die active-daemon-arguments-unavailable
    [ -n "$command_line" ] || die active-daemon-arguments-unavailable
    # Include the caller path, canonical path, and verified macOS alias.
    # A daemon can name the logical alias before its socket listener exists.
    # Require the data-dir flag/value boundary, including descendants.
    for copy_path in "$copy" "$copy_real" "$logical_copy"; do
      [ -n "$copy_path" ] || continue
      case " $command_line " in
        *" --data-dir $copy_path "*|*" --data-dir=$copy_path "*|\
        *" --data-dir $copy_path/"*|*" --data-dir=$copy_path/"*)
          die copy-is-named-by-active-daemon ;;
      esac
    done
  done <<< "$processes"
}

check_primary_and_copy
if [ "$execute" -eq 0 ]; then
  printf 'RETAINED_COPY_CLEANUP=ready copy=%s primary_pid=%s\n' "$copy_real" "$expected_pid"
  exit 0
fi

timeout_bin="$(command -v gtimeout || command -v timeout || true)"
[ -n "$timeout_bin" ] || die timeout-command-absent
check_primary_and_copy
"$timeout_bin" -s TERM 600 rm -rf -x -- "$copy_real" \
  || die deletion-failed-or-timed-out-partial-copy-retained
printf 'RETAINED_COPY_CLEANUP=released copy=%s\n' "$copy_real"
