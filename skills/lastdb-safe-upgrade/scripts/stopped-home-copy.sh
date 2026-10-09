#!/usr/bin/env bash
# Make one cloud-backup source from a stopped LastDB primary.
# The old daemon has no flush receipt; its one-time waiver must be explicit.
# Run only while Cloud Sync is Off and after the required primary checks.
# The copy can use /private/tmp or the exact private STATE source-copies parent.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=launchd-job-checks.sh
. "$SCRIPT_DIR/launchd-job-checks.sh"
# shellcheck source=live-socket-health.sh
. "$SCRIPT_DIR/live-socket-health.sh"
# shellcheck source=owner-lock.sh
. "$SCRIPT_DIR/owner-lock.sh"

MIN_FREE_KIB=31457280 # 30 GiB; checked before stop and after the copy.
MAX_DISK_DROP_KIB=23068672 # 22 GiB; an APFS clone must not consume a full home.
MAX_COPY_SECS=600
WAIVER_DECISION_SLUG=decision-2026-10-06-cloud-sync-rescue-risk-acceptance
WAIVER_CLAIM_FILE=.cloud_backup_unproved_flush_claim
COPY_DIR=""
STAGE_COPY=""
PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
SIDEBIN_DIR="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}"
LAUNCHD_LABEL="${LASTDB_LAUNCHD_LABEL:-}"
LAUNCHD_PLIST="${LASTDB_LAUNCHD_PLIST:-}"
LAUNCHCTL_BIN="launchctl"
EXPECTED_DAEMON_SHA=""
EXPECTED_CLI_SHA=""
ACCEPT_UNPROVED_FLUSH=""
WAIVER_CLAIMED=0
SOURCE_START_TS=""
OWNER_LOCK_DIR="/tmp/lastdb-safe-upgrade-owner-$(id -u).lock.d"
OWNER_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
OWNER_LOCK_HELD=0
STOP_STARTED=0
RESTARTED=0
RESTART_REQUESTED=0
OLD_PID=""

fail() { printf 'STOPPED_COPY=red reason=%s\n' "$1" >&2; return 1; }

free_kib() {
  local path="$1" value
  value="$(df -Pk "$path" | awk 'NR==2 {print $4}')" || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

require_disk_floor() {
  local path="$1" free
  free="$(free_kib "$path")" || fail disk-free-unreadable
  [ "$free" -ge "$MIN_FREE_KIB" ] || fail disk-free-below-30-gib
  printf '%s\n' "$free"
}

validate_copy_path() {
  local copy="$1" home="$2" parent parent_real home_real durable_parent
  case "$copy" in /*) ;; *) fail copy-path-not-absolute; return 1 ;; esac
  [ "$copy" = "${copy%/}" ] || { fail copy-path-trailing-slash; return 1; }
  [ ! -e "$copy" ] && [ ! -L "$copy" ] || { fail copy-path-exists; return 1; }
  parent="$(dirname -- "$copy")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || { fail copy-parent-unsafe; return 1; }
  parent_real="$(CDPATH= cd -- "$parent" && pwd -P)" || return 1
  home_real="$(CDPATH= cd -- "$home" && pwd -P)" || return 1
  [ "$parent_real" = "$parent" ] || { fail copy-parent-not-canonical; return 1; }
  durable_parent="$HOME/.local/state/last-stack/cloud-rescue/source-copies"
  case "$parent_real" in
    /private/tmp|/private/tmp/*) ;;
    "$durable_parent")
      [ "$(stat -f '%u' "$parent_real")" = "$(id -u)" ] \
        && [ "$(stat -f '%Lp' "$parent_real")" = 700 ] \
        || { fail copy-parent-not-private; return 1; }
      ;;
    *) fail copy-parent-not-approved; return 1 ;;
  esac
  case "$parent_real" in
    "$home_real"|"$home_real"/*)
      fail copy-under-home; return 1 ;;
  esac
  [ "$(stat -f '%d' "$parent_real")" = "$(stat -f '%d' "$home_real")" ] \
    || { fail copy-on-other-device; return 1; }
}

validate_cloud_off_home() {
  local home="$1" mode="${2:-receipt}"
  [ ! -e "$home/cloud_sync.json" ] && [ ! -L "$home/cloud_sync.json" ] \
    || { fail cloud-config-active; return 1; }
  [ -f "$home/cloud_sync.json.paused" ] && [ ! -L "$home/cloud_sync.json.paused" ] \
    || { fail paused-cloud-config-absent; return 1; }
  case "$mode" in
    receipt)
      [ -f "$home/.cloud_resume_required" ] && [ ! -L "$home/.cloud_resume_required" ] \
        || { fail resume-required-marker-absent; return 1; }
      ;;
    waiver)
      if [ -e "$home/.cloud_resume_required" ] || [ -L "$home/.cloud_resume_required" ]; then
        [ -f "$home/.cloud_resume_required" ] && [ ! -L "$home/.cloud_resume_required" ] \
          || { fail resume-required-marker-unsafe; return 1; }
      fi
      ;;
    *) fail cloud-off-mode-invalid; return 1 ;;
  esac
  [ ! -e "$home/.cloud_resume_requested" ] && [ ! -L "$home/.cloud_resume_requested" ] \
    || { fail live-resume-request-present; return 1; }
  [ ! -e "$home/.cloud_resume_ready" ] && [ ! -L "$home/.cloud_resume_ready" ] \
    || { fail stale-resume-receipt-present; return 1; }
  [ ! -e "$home/.cloud_backup_source_copy" ] && [ ! -L "$home/.cloud_backup_source_copy" ] \
    || { fail source-copy-marker-on-live-home; return 1; }
}

require_restart_preflight() {
  local result
  result="$(situations preflight --action restart --system lastdbd --json 2>/dev/null)" \
    || { fail situations-preflight-unavailable-or-blocked; return 1; }
  printf '%s\n' "$result" \
    | jq -e '.ok == true and (.blocks | type) == "array" and (.blocks | length) == 0' >/dev/null \
    || { fail situations-preflight-unavailable-or-blocked; return 1; }
}

validate_shutdown_receipt() {
  local home="$1" pid="$2" start_ts="$3" path
  path="$home/.shutdown_flush_ready"
  [ -f "$path" ] && [ ! -L "$path" ] || { fail shutdown-flush-receipt-absent; return 1; }
  jq -e --argjson pid "$pid" --argjson start_ts "$start_ts" '
    (keys | sort) == (["flush_ok","pid","start_ts","version"] | sort)
    and .version == 1 and .pid == $pid and .start_ts == $start_ts
    and .flush_ok == true
  ' "$path" >/dev/null || { fail shutdown-flush-receipt-mismatch; return 1; }
}

verify_stopped_session() {
  local home="$1" pid="$2" start_ts="$3" service="$4" session ledger ledger_size
  session="$home/current-session.json"
  ledger="$home/sessions.jsonl"
  ! kill -0 "$pid" 2>/dev/null \
    && ! lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" \
    && ! live_unix_socket_has_listener "$home/data/folddb.sock" \
    && ! live_unix_socket_has_listener "$home/data/folddb-full.sock" \
    || { fail old-daemon-still-serving; return 1; }
  [ -f "$ledger" ] && [ ! -L "$ledger" ] \
    || { fail stopped-session-ledger-unsafe; return 1; }
  ledger_size="$(stat -f '%z' "$ledger")" || { fail stopped-session-ledger-unreadable; return 1; }
  [ "$ledger_size" -le 16777216 ] \
    || { fail stopped-session-ledger-over-16-mib; return 1; }
  jq -se --argjson pid "$pid" --argjson start_ts "$start_ts" '
    all(.[]; type == "object" and (.pid | type) == "number"
      and (.start_ts | type) == "number")
    and ([ .[] | select(.pid == $pid and .start_ts == $start_ts) ] as $matches |
      ($matches | length) == 1 and $matches[0].exit == "clean"
      and ($matches[0].end_ts | type) == "number"
      and $matches[0].end_ts >= $start_ts)
  ' "$ledger" >/dev/null || { fail stopped-session-ledger-not-clean; return 1; }
  if [ ! -e "$session" ] && [ ! -L "$session" ]; then
    return 0
  fi
  [ -f "$session" ] && [ ! -L "$session" ] \
    || { fail stopped-session-marker-unsafe; return 1; }
  jq -se --argjson pid "$pid" --argjson start_ts "$start_ts" '
    length == 1 and (.[0] | type) == "object"
    and (.[0] | keys | sort) == (["pid","start_ts","last_heartbeat_ts"] | sort)
    and .[0].pid == $pid and .[0].start_ts == $start_ts
    and (.[0].last_heartbeat_ts | type) == "number"
    and .[0].last_heartbeat_ts >= .[0].start_ts
  ' "$session" >/dev/null || { fail stopped-session-marker-mismatch; return 1; }
  shasum -a 256 "$session" | awk '{print $1}'
}

verify_stopped_receipt_session() {
  local home="$1" pid="$2" start_ts="$3" service="$4" session_sha
  # A detached heartbeat can leave this marker after a clean exit. Accept it
  # only with the same stopped-session proof and an exact final-flush receipt.
  session_sha="$(verify_stopped_session "$home" "$pid" "$start_ts" "$service")" \
    || return 1
  validate_shutdown_receipt "$home" "$pid" "$start_ts" || return 1
  printf '%s\n' "$session_sha"
}

require_plain_data_tree() {
  local data="$1" timeout_bin="$2" special
  [ -d "$data" ] && [ ! -L "$data" ] || { fail data-root-unsafe; return 1; }
  # walk-ok: the exact LastDB data tree needs a full path check before upload.
  special="$("$timeout_bin" -s TERM 120 find "$data" ! -type f ! -type d -print -quit)" \
    || { fail data-path-check-failed; return 1; }
  [ -z "$special" ] || { fail data-special-path-present; return 1; }
}

transient_search_inbox_cp_error_count() {
  local errors="$1" home="$2" line name count=0
  local prefix="cp: $home/apps/search/inbox/"
  local suffix=": No such file or directory"
  [ -s "$errors" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$prefix"*"$suffix") ;;
      *) return 1 ;;
    esac
    name="${line#"$prefix"}"
    name="${name%"$suffix"}"
    [[ "$name" =~ ^[0-9]{13}_[0-9a-f]{32}\.json$ ]] || return 1
    count=$((count + 1))
  done < "$errors"
  [ "$count" -gt 0 ] || return 1
  printf '%s\n' "$count"
}

copy_stopped_home() {
  local home="$1" copy="$2" timeout_bin="$3" before_free="$4" mode="${5:-receipt}" session_sha="${6:-}" after_free
  local cp_errors cp_status ignored drift
  # The stopped daemon no longer owns these socket names. They cannot be
  # cloned, and the next daemon creates them again when it starts.
  for sock in "$home/data/folddb.sock" "$home/data/folddb-full.sock"; do
    if [ -e "$sock" ] || [ -L "$sock" ]; then
      [ -S "$sock" ] && ! live_unix_socket_has_listener "$sock" \
        || { fail source-socket-still-live; return 1; }
      unlink_stale_unix_socket "$sock" >/dev/null || return 1
    fi
  done
  require_plain_data_tree "$home/data" "$timeout_bin" || return 1
  cp_errors="$(mktemp "${TMPDIR:-/private/tmp}/lastdb-stopped-copy-cp.XXXXXX")" \
    || { fail stopped-copy-error-capture-failed; return 1; }
  if (umask 077; "$timeout_bin" -s TERM "$MAX_COPY_SECS" cp -cR "$home" "$copy") \
    2>"$cp_errors"; then
    [ ! -s "$cp_errors" ] || { fail stopped-copy-unexpected-stderr; return 1; }
  else
    cp_status=$?
    [ "$cp_status" -eq 1 ] || { fail stopped-copy-failed; return 1; }
    ignored="$(transient_search_inbox_cp_error_count "$cp_errors" "$home")" \
      || { fail stopped-copy-failed; return 1; }
    # Search can move a batch to done/ while cp walks the inbox. The publisher
    # reads data/ only. Verify every data path and size before accepting the copy.
    drift="$("$timeout_bin" -s TERM 120 rsync --dry-run --recursive \
      --itemize-changes --size-only --delete "$home/data/" "$copy/data/")" \
      || { fail stopped-copy-data-compare-failed; return 1; }
    [ -z "$drift" ] || { fail stopped-copy-data-path-or-size-mismatch; return 1; }
    printf 'STOPPED_COPY_CP=transient-search-inbox-move count=%s\n' "$ignored"
  fi
  [ -d "$copy" ] && [ ! -L "$copy" ] \
    && [ -f "$copy/identity.key" ] && [ ! -L "$copy/identity.key" ] \
    && [ -d "$copy/data" ] \
    && { [ -e "$copy/data/db" ] || [ -d "$copy/data/data" ] || [ -d "$copy/data/laststore" ]; } \
    || { fail stopped-copy-incomplete; return 1; }
  chmod 700 "$copy" || { fail stopped-copy-permissions; return 1; }
  require_plain_data_tree "$copy/data" "$timeout_bin" || return 1
  [ "$(shasum -a 256 "$home/identity.key" | awk '{print $1}')" = \
    "$(shasum -a 256 "$copy/identity.key" | awk '{print $1}')" ] \
    && cmp -s "$home/cloud_sync.json.paused" "$copy/cloud_sync.json.paused" \
    || { fail stopped-copy-critical-bytes-mismatch; return 1; }
  if [ "$mode" = receipt ]; then
    cmp -s "$home/.shutdown_flush_ready" "$copy/.shutdown_flush_ready" \
      || { fail stopped-copy-receipt-mismatch; return 1; }
  else
    cmp -s "$home/$WAIVER_CLAIM_FILE" "$copy/$WAIVER_CLAIM_FILE" \
      || { fail stopped-copy-waiver-claim-mismatch; return 1; }
  fi
  if [ -n "$session_sha" ]; then
    [ -f "$home/current-session.json" ] && [ ! -L "$home/current-session.json" ] \
      && [ -f "$copy/current-session.json" ] && [ ! -L "$copy/current-session.json" ] \
      && [ "$(shasum -a 256 "$home/current-session.json" | awk '{print $1}')" = "$session_sha" ] \
      && [ "$(shasum -a 256 "$copy/current-session.json" | awk '{print $1}')" = "$session_sha" ] \
      && cmp -s "$home/current-session.json" "$copy/current-session.json" \
      || { fail stopped-copy-session-bytes-mismatch; return 1; }
    unlink "$copy/current-session.json" \
      || { fail stopped-copy-session-remove-failed; return 1; }
    printf 'STOPPED_COPY_SESSION=copy-only-remove sha256=%s\n' "$session_sha"
  fi
  validate_cloud_off_home "$copy" "$mode" || return 1
  [ ! -e "$copy/current-session.json" ] && [ ! -L "$copy/current-session.json" ] \
    || { fail stopped-copy-live-session-present; return 1; }
  for sock in "$copy/data/folddb.sock" "$copy/data/folddb-full.sock"; do
    [ ! -e "$sock" ] && [ ! -L "$sock" ] \
      || { fail stopped-copy-socket-present; return 1; }
  done
  after_free="$(require_disk_floor "$copy")" || return 1
  [ "$((before_free - after_free))" -le "$MAX_DISK_DROP_KIB" ] \
    || { fail stopped-copy-disk-drop-over-22-gib; return 1; }
}

restart_primary() {
  local domain="$1" label="$2" plist="$3" sock="$4" job_pid listener_pid
  RESTART_REQUESTED=1
  lastdb_launchd_reload_job "$LAUNCHCTL_BIN" "$domain" "$label" "$plist" || return 1
  wait_for_live_unix_socket_health "$sock" 180 || return 1
  job_pid="$(lastdb_launchd_job_pid "$LAUNCHCTL_BIN" "$domain/$label")"
  listener_pid="$(live_unix_socket_health_pid "$sock" || true)"
  [ -n "$job_pid" ] && [ "$job_pid" = "$listener_pid" ] || return 1
  lastdb_require_supervised_primary "$LAUNCHCTL_BIN" "$domain/$label" "$listener_pid" >/dev/null
}

primary_is_supervised_and_healthy() {
  local domain="$1" label="$2" sock="$3" job_pid listener_pid
  live_unix_socket_is_healthy "$sock" || return 1
  job_pid="$(lastdb_launchd_job_pid "$LAUNCHCTL_BIN" "$domain/$label")"
  listener_pid="$(live_unix_socket_health_pid "$sock" || true)"
  [ -n "$job_pid" ] && [ "$job_pid" = "$listener_pid" ] || return 1
  lastdb_require_supervised_primary "$LAUNCHCTL_BIN" "$domain/$label" "$listener_pid" >/dev/null
}

require_live_cloud_off() {
  local sock="$1"
  curl -fsS --max-time 15 --unix-socket "$sock" \
    -H 'X-LastDB-Client: lastdb-safe-upgrade' http://localhost/api/status \
    | jq -e '.status.sync.enabled == false' >/dev/null \
    || { fail live-cloud-sync-not-off; return 1; }
}

bootstrap_absent_primary_once() {
  local domain="$1" label="$2" plist="$3" sock="$4" service
  service="$domain/$label"
  [ -x "$SIDEBIN_DIR/lastdbd" ] \
    && ! lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" \
    && ! live_unix_socket_has_listener "$sock" \
    || return 1
  # A failed bootstrap can still load the job. Judge the supervisor state.
  "$LAUNCHCTL_BIN" bootstrap "$domain" "$plist" \
    || lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" || return 1
  lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" || return 1
  wait_for_live_unix_socket_health "$sock" 180 || return 1
  primary_is_supervised_and_healthy "$domain" "$label" "$sock"
}

recover_on_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [ "$STOP_STARTED" -eq 1 ] && [ "$RESTARTED" -eq 0 ]; then
    # Strict pre-stop moves the program aside to prevent a KeepAlive respawn.
    # Restore the same candidate bytes if a signal interrupted that helper.
    if [ ! -e "$SIDEBIN_DIR/lastdbd" ] && [ -f "$SIDEBIN_DIR/lastdbd.prestop-hold" ]; then
      mv -f -- "$SIDEBIN_DIR/lastdbd.prestop-hold" "$SIDEBIN_DIR/lastdbd" || true
    fi
    if primary_is_supervised_and_healthy "gui/$(id -u)" "$LAUNCHD_LABEL" "$PRIMARY_HOME/data/folddb.sock"; then
      printf 'STOPPED_COPY_RECOVERY=green primary=running cloud=off\n' >&2
    elif lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "gui/$(id -u)/$LAUNCHD_LABEL"; then
      # The old process may still run, or a requested bootstrap may still boot.
      # Do not send a second reload to a loaded supervisor.
      if wait_for_live_unix_socket_health "$PRIMARY_HOME/data/folddb.sock" 180 >/dev/null \
        && primary_is_supervised_and_healthy "gui/$(id -u)" "$LAUNCHD_LABEL" "$PRIMARY_HOME/data/folddb.sock"; then
        printf 'STOPPED_COPY_RECOVERY=green primary=running cloud=off\n' >&2
      else
        printf 'STOPPED_COPY_RECOVERY=red primary=loaded-but-unhealthy action=inspect-launchd\n' >&2
        rc=1
      fi
    elif [ "$RESTART_REQUESTED" -eq 1 ]; then
      if bootstrap_absent_primary_once "gui/$(id -u)" "$LAUNCHD_LABEL" \
        "$LAUNCHD_PLIST" "$PRIMARY_HOME/data/folddb.sock"; then
        printf 'STOPPED_COPY_RECOVERY=green primary=running method=single-bootstrap cloud=off\n' >&2
      else
        printf 'STOPPED_COPY_RECOVERY=red primary=unloaded-after-restart-request action=inspect-launchd\n' >&2
        rc=1
      fi
    elif restart_primary "gui/$(id -u)" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST" "$PRIMARY_HOME/data/folddb.sock"; then
      printf 'STOPPED_COPY_RECOVERY=green primary=running cloud=off\n' >&2
    else
      printf 'STOPPED_COPY_RECOVERY=red primary=unhealthy action=inspect-launchd\n' >&2
      rc=1
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$WAIVER_CLAIMED" -eq 1 ]; then
    if [ ! -e "$COPY_DIR" ] && [ ! -L "$COPY_DIR" ] \
      && [ ! -e "$STAGE_COPY/.cloud_backup_source_copy" ] \
      && primary_is_supervised_and_healthy "gui/$(id -u)" "$LAUNCHD_LABEL" "$PRIMARY_HOME/data/folddb.sock" \
      && validate_cloud_off_home "$PRIMARY_HOME" waiver \
      && require_live_cloud_off "$PRIMARY_HOME/data/folddb.sock" \
      && python3 "$SCRIPT_DIR/claim-stopped-copy-waiver.py" --release \
        --home "$PRIMARY_HOME" --pid "$OLD_PID" --start-ts "$SOURCE_START_TS" \
        --copy-path "$COPY_DIR" --decision-slug "$ACCEPT_UNPROVED_FLUSH"; then
      printf 'STOPPED_COPY_WAIVER=available_after_failed_copy primary=recovered\n' >&2
    else
      printf 'STOPPED_COPY_WAIVER=consumed reason=copy-or-primary-not-proved action=review-source\n' >&2
    fi
  fi
  safe_upgrade_owner_lock_release "$OWNER_LOCK_DIR" "$OWNER_LOCK_TOKEN" "$OWNER_LOCK_HELD" \
    || rc=1
  exit "$rc"
}

main() {
  local service plist_program job_pid listener_pid start_ts before_free timeout_bin stop_out notice_summary flush_proof session_sha
  local actual_daemon_sha actual_cli_sha
  session_sha=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --copy) COPY_DIR="${2:-}"; shift 2 ;;
      --launchd-label) LAUNCHD_LABEL="${2:-}"; shift 2 ;;
      --primary-home) PRIMARY_HOME="${2:-}"; shift 2 ;;
      --expected-lastdbd-sha256) EXPECTED_DAEMON_SHA="${2:-}"; shift 2 ;;
      --expected-lastdb-sha256) EXPECTED_CLI_SHA="${2:-}"; shift 2 ;;
      --accept-unproved-flush) ACCEPT_UNPROVED_FLUSH="${2:-}"; shift 2 ;;
      *) fail unknown-argument; return 2 ;;
    esac
  done
  [ -n "$COPY_DIR" ] && [ -n "$LAUNCHD_LABEL" ] || { fail required-argument-absent; return 2; }
  if [ -n "$ACCEPT_UNPROVED_FLUSH" ] && [ "$ACCEPT_UNPROVED_FLUSH" != "$WAIVER_DECISION_SLUG" ]; then
    fail unproved-flush-decision-mismatch; return 2
  fi
  local mode=receipt
  [ -z "$ACCEPT_UNPROVED_FLUSH" ] || mode=waiver
  [ "${#EXPECTED_DAEMON_SHA}" -eq 64 ] && [ "${#EXPECTED_CLI_SHA}" -eq 64 ] \
    && [[ "$EXPECTED_DAEMON_SHA" =~ ^[0-9a-f]+$ ]] \
    && [[ "$EXPECTED_CLI_SHA" =~ ^[0-9a-f]+$ ]] \
    || { fail expected-binary-hashes-absent; return 2; }
  case "$LAUNCHD_LABEL" in ''|com.REPLACE.*|*[!A-Za-z0-9._-]*) fail launchd-label-invalid; return 2 ;; esac
  [ -d "$PRIMARY_HOME" ] && [ ! -L "$PRIMARY_HOME" ] || { fail primary-home-unsafe; return 1; }
  [ -f "$PRIMARY_HOME/identity.key" ] && [ ! -L "$PRIMARY_HOME/identity.key" ] \
    || { fail primary-identity-unsafe; return 1; }
  [ -x "$SIDEBIN_DIR/lastdbd" ] || { fail installed-daemon-absent; return 1; }
  [ -x "$SIDEBIN_DIR/lastdb" ] || { fail installed-cli-absent; return 1; }
  actual_daemon_sha="$(shasum -a 256 "$SIDEBIN_DIR/lastdbd" | awk '{print $1}')"
  actual_cli_sha="$(shasum -a 256 "$SIDEBIN_DIR/lastdb" | awk '{print $1}')"
  [ "$actual_daemon_sha" = "$EXPECTED_DAEMON_SHA" ] \
    && [ "$actual_cli_sha" = "$EXPECTED_CLI_SHA" ] \
    || { fail installed-candidate-bytes-mismatch; return 1; }
  LAUNCHD_PLIST="${LAUNCHD_PLIST:-$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist}"
  [ -f "$LAUNCHD_PLIST" ] && [ ! -L "$LAUNCHD_PLIST" ] \
    || { fail launchd-plist-unsafe; return 1; }
  plist_program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD_PLIST" 2>/dev/null || true)"
  [ "$plist_program" = "$SIDEBIN_DIR/lastdbd" ] \
    || { fail launchd-program-mismatch; return 1; }
  validate_copy_path "$COPY_DIR" "$PRIMARY_HOME" || return 1
  STAGE_COPY="${COPY_DIR}.incomplete"
  validate_copy_path "$STAGE_COPY" "$PRIMARY_HOME" || return 1
  validate_cloud_off_home "$PRIMARY_HOME" "$mode" || return 1
  if [ "$mode" = waiver ]; then
    [ ! -e "$PRIMARY_HOME/$WAIVER_CLAIM_FILE" ] \
      && [ ! -L "$PRIMARY_HOME/$WAIVER_CLAIM_FILE" ] \
      || { fail unproved-flush-waiver-already-used; return 1; }
  fi
  [ ! -e "$PRIMARY_HOME/.shutdown_flush_ready" ] \
    || { fail stale-shutdown-receipt-present; return 1; }
  timeout_bin="$(command -v gtimeout || command -v timeout || true)"
  [ -n "$timeout_bin" ] || { fail copy-timeout-command-absent; return 1; }
  command -v rsync >/dev/null || { fail copy-data-compare-command-absent; return 1; }
  [ "$(uname -s)" = Darwin ] || { fail apfs-clone-unavailable; return 1; }
  # A blocked or unreadable Situation leaves the primary and the copy path untouched.
  require_restart_preflight || return 1
  safe_upgrade_owner_lock_acquire "$OWNER_LOCK_DIR" "$OWNER_LOCK_TOKEN" "$$" \
    "$SIDEBIN_DIR/lastdbd" stopped-copy \
    || { fail upgrade-owner-lock-busy; return 1; }
  OWNER_LOCK_HELD=1
  trap recover_on_exit EXIT
  trap 'exit 143' HUP INT TERM
  before_free="$(require_disk_floor "$PRIMARY_HOME")" || return 1
  service="gui/$(id -u)/$LAUNCHD_LABEL"
  job_pid="$(lastdb_launchd_job_pid "$LAUNCHCTL_BIN" "$service")"
  listener_pid="$(live_unix_socket_health_pid "$PRIMARY_HOME/data/folddb.sock" || true)"
  [ -n "$job_pid" ] && [ "$job_pid" = "$listener_pid" ] \
    && live_unix_socket_is_healthy "$PRIMARY_HOME/data/folddb.sock" \
    || { fail primary-not-supervised-and-healthy; return 1; }
  start_ts="$(jq -er --argjson pid "$job_pid" \
    'select(.pid == $pid and (.start_ts | type) == "number") | .start_ts' \
    "$PRIMARY_HOME/current-session.json")" \
    || { fail live-session-identity-absent; return 1; }
  OLD_PID="$job_pid"
  SOURCE_START_TS="$start_ts"
  STOP_STARTED=1
  stop_out="$(lastdb_launchd_graceful_prestop "$LAUNCHCTL_BIN" "$service" \
    "$SIDEBIN_DIR/lastdbd" 300 150 1)" \
    || { fail strict-stop-failed; return 1; }
  case "$stop_out" in *'LASTDB_LAUNCHD_PRESTOP=ok '*'forced_kill=0'*) ;; *) fail strict-stop-unproved; return 1 ;; esac
  ! kill -0 "$OLD_PID" 2>/dev/null && ! lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" \
    && ! live_unix_socket_has_listener "$PRIMARY_HOME/data/folddb.sock" \
    && ! live_unix_socket_has_listener "$PRIMARY_HOME/data/folddb-full.sock" \
    || { fail old-daemon-still-serving; return 1; }
  if [ "$mode" = receipt ]; then
    session_sha="$(verify_stopped_receipt_session "$PRIMARY_HOME" "$OLD_PID" "$start_ts" "$service")" \
      || return 1
  else
    session_sha="$(verify_stopped_session "$PRIMARY_HOME" "$OLD_PID" "$start_ts" "$service")" \
      || return 1
    [ ! -e "$PRIMARY_HOME/.shutdown_flush_ready" ] \
      && [ ! -L "$PRIMARY_HOME/.shutdown_flush_ready" ] \
      || { fail unproved-flush-receipt-present; return 1; }
    python3 "$SCRIPT_DIR/claim-stopped-copy-waiver.py" \
      --home "$PRIMARY_HOME" --pid "$OLD_PID" --start-ts "$start_ts" \
      --copy-path "$COPY_DIR" --decision-slug "$ACCEPT_UNPROVED_FLUSH" \
      || { fail unproved-flush-waiver-claim-failed; return 1; }
    WAIVER_CLAIMED=1
  fi
  copy_stopped_home "$PRIMARY_HOME" "$STAGE_COPY" "$timeout_bin" "$before_free" "$mode" "$session_sha" || return 1
  if [ "$mode" = receipt ]; then
    validate_shutdown_receipt "$STAGE_COPY" "$OLD_PID" "$start_ts" || return 1
  fi
  restart_primary "gui/$(id -u)" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST" "$PRIMARY_HOME/data/folddb.sock" \
    || { fail primary-restart-failed; return 1; }
  RESTARTED=1
  validate_cloud_off_home "$PRIMARY_HOME" "$mode" || return 1
  require_live_cloud_off "$PRIMARY_HOME/data/folddb.sock" || return 1
  [ ! -e "$PRIMARY_HOME/.shutdown_flush_ready" ] \
    && [ ! -L "$PRIMARY_HOME/.shutdown_flush_ready" ] \
    || { fail live-shutdown-receipt-survived-restart; return 1; }
  actual_daemon_sha="$(shasum -a 256 "$SIDEBIN_DIR/lastdbd" | awk '{print $1}')"
  actual_cli_sha="$(shasum -a 256 "$SIDEBIN_DIR/lastdb" | awk '{print $1}')"
  [ "$actual_daemon_sha" = "$EXPECTED_DAEMON_SHA" ] \
    && [ "$actual_cli_sha" = "$EXPECTED_CLI_SHA" ] \
    || { fail installed-candidate-changed-after-restart; return 1; }
  if [ "$mode" = waiver ]; then
    notice_summary='The primary restarted after a stopped APFS copy; source flush proof is absent by owner approval; Cloud Sync remains Off.'
    flush_proof=absent
  else
    notice_summary='The primary restarted after a verified flush and APFS copy; Cloud Sync remains Off.'
    flush_proof=verified
  fi
  situations notice --title 'LastDB stopped copy complete' --kind restart \
    --system lastdbd --actor skill:lastdb-safe-upgrade \
    --summary "$notice_summary" \
    >/dev/null || { fail situations-notice-failed; return 1; }
  mv -- "$STAGE_COPY" "$COPY_DIR" || { fail stopped-copy-publish-failed; return 1; }
  local marker_args=(--copy "$COPY_DIR" --pid "$OLD_PID" --start-ts "$start_ts")
  if [ "$mode" = waiver ]; then
    marker_args+=(--accept-unproved-flush "$ACCEPT_UNPROVED_FLUSH")
  fi
  python3 "$SCRIPT_DIR/write-stopped-copy-marker.py" "${marker_args[@]}" \
    || { fail stopped-copy-marker-failed; return 1; }
  printf 'STOPPED_COPY=green path=%s source_pid=%s cloud=off flush_proof=%s\n' \
    "$COPY_DIR" "$OLD_PID" "$flush_proof"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
