#!/usr/bin/env bash
# One host-wide owner lock for the complete LastDB safe-upgrade process.
# This file defines functions only. It has no side effects when sourced.

safe_upgrade_owner_lock_age_seconds() {
  local path="$1" now mtime
  now="$(date +%s 2>/dev/null || echo 0)"
  mtime="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0)"
  if [ "$now" -gt 0 ] 2>/dev/null && [ "$mtime" -gt 0 ] 2>/dev/null && [ "$now" -ge "$mtime" ] 2>/dev/null; then
    printf '%s\n' "$((now - mtime))"
  else
    printf '0\n'
  fi
}

safe_upgrade_owner_lock_pid() {
  local lock_dir="$1"
  if [ -f "$lock_dir/owner" ]; then
    sed -n 's/^pid=//p' "$lock_dir/owner" | head -1
  elif [ -f "$lock_dir/pid" ]; then
    sed -n '1p' "$lock_dir/pid"
  fi
}

safe_upgrade_owner_lock_write() {
  local lock_dir="$1" token="$2" owner_pid="$3" candidate="$4" mode="$5"
  printf '%s\n' "$owner_pid" >"$lock_dir/pid"
  {
    printf 'pid=%s\n' "$owner_pid"
    printf 'token=%s\n' "$token"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'candidate=%s\n' "$candidate"
    printf 'mode=%s\n' "$mode"
  } >"$lock_dir/owner"
}

safe_upgrade_owner_lock_quarantine() {
  local lock_dir="$1" token="$2" stale_dir
  stale_dir="${lock_dir}.reclaim.${token}"
  if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
    rm -f "$stale_dir/pid" "$stale_dir/owner"
    rmdir "$stale_dir" 2>/dev/null || {
      printf '[safe-upgrade] ERROR: stale owner lock contains unexpected files: %s\n' "$stale_dir" >&2
      return 1
    }
    return 0
  fi
  return 1
}

safe_upgrade_owner_lock_acquire() {
  local lock_dir="$1" token="$2" owner_pid="$3" candidate="$4" mode="$5"
  local parent existing_pid age grace
  grace="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_INIT_GRACE_S:-60}"
  case "$lock_dir" in
    ""|/|/tmp|/private/tmp)
      printf '[safe-upgrade] ERROR: unsafe owner lock path: %s\n' "$lock_dir" >&2
      return 1
      ;;
    *.lock.d) ;;
    *)
      printf '[safe-upgrade] ERROR: owner lock path must end in .lock.d: %s\n' "$lock_dir" >&2
      return 1
      ;;
  esac
  case "$grace" in
    ""|*[!0-9]*)
      printf '[safe-upgrade] ERROR: owner lock init grace must be a non-negative integer\n' >&2
      return 1
      ;;
  esac
  parent="$(dirname "$lock_dir")"
  mkdir -p "$parent"
  if [ -L "$lock_dir" ]; then
    printf '[safe-upgrade] ERROR: owner lock must not be a symlink: %s\n' "$lock_dir" >&2
    return 1
  fi
  if mkdir "$lock_dir" 2>/dev/null; then
    safe_upgrade_owner_lock_write "$lock_dir" "$token" "$owner_pid" "$candidate" "$mode"
    return 0
  fi
  [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || {
    printf '[safe-upgrade] ERROR: owner lock path is not a directory: %s\n' "$lock_dir" >&2
    return 1
  }
  existing_pid="$(safe_upgrade_owner_lock_pid "$lock_dir")"
  if [ -n "$existing_pid" ] && printf '%s' "$existing_pid" | grep -Eq '^[0-9]+$' \
      && kill -0 "$existing_pid" 2>/dev/null; then
    printf '[safe-upgrade] ERROR: owner lock active: %s pid=%s\n' "$lock_dir" "$existing_pid" >&2
    return 1
  fi
  age="$(safe_upgrade_owner_lock_age_seconds "$lock_dir")"
  if [ -z "$existing_pid" ] && [ "$age" -lt "$grace" ] 2>/dev/null; then
    printf '[safe-upgrade] ERROR: owner lock initialization active: %s age=%ss\n' "$lock_dir" "$age" >&2
    return 1
  fi
  safe_upgrade_owner_lock_quarantine "$lock_dir" "$token" || return 1
  if ! mkdir "$lock_dir" 2>/dev/null; then
    printf '[safe-upgrade] ERROR: owner lock changed during stale recovery: %s\n' "$lock_dir" >&2
    return 1
  fi
  safe_upgrade_owner_lock_write "$lock_dir" "$token" "$owner_pid" "$candidate" "$mode"
  return 0
}

safe_upgrade_owner_lock_acquire_wait() {
  # Bounded wait around acquire. Contention (a live owner, init grace, or a
  # stale-recovery race against a releaser) is retried until
  # LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S expires; every other acquire error
  # returns at once. wait=0 keeps today's fail-fast behavior.
  # Loom re-dispatches a node whose worker lease lapsed while the first
  # attempt's process tree still holds this lock (exec
  # lx-20260831T143453.167-37523-1) — the re-run must wait, not mark the
  # candidate RED.
  #
  # Budget uses $SECONDS (monotonic in this shell), not `date +%s`. A failed
  # date that fell back to 0 used to set deadline=wait_s and then treat the
  # next real epoch as expiry, so a live holder that released inside the
  # budget was never observed.
  local lock_dir="$1" token="$2" owner_pid="$3" candidate="$4" mode="$5"
  local wait_s poll started elapsed err announced=0
  wait_s="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S:-0}"
  poll="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_POLL_S:-15}"
  case "$wait_s" in
    ""|*[!0-9]*)
      printf '[safe-upgrade] ERROR: owner lock wait must be a non-negative integer\n' >&2
      return 1
      ;;
  esac
  case "$poll" in
    ""|0|*[!0-9]*)
      printf '[safe-upgrade] ERROR: owner lock poll must be a positive integer\n' >&2
      return 1
      ;;
  esac
  started="$SECONDS"
  while :; do
    if err="$(safe_upgrade_owner_lock_acquire \
        "$lock_dir" "$token" "$owner_pid" "$candidate" "$mode" 2>&1)"; then
      [ -z "$err" ] || printf '%s\n' "$err" >&2
      return 0
    fi
    case "$err" in
      *"owner lock active"*|*"owner lock initialization active"*|*"owner lock changed during stale recovery"*) ;;
      *)
        printf '%s\n' "$err" >&2
        return 1
        ;;
    esac
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge "$wait_s" ]; then
      printf '%s\n' "$err" >&2
      if [ "$wait_s" -gt 0 ]; then
        printf '[safe-upgrade] ERROR: owner lock still busy after %ss wait\n' "$wait_s" >&2
      fi
      return 1
    fi
    if [ "$announced" -eq 0 ]; then
      printf '[safe-upgrade] owner lock busy — waiting up to %ss (poll %ss): %s\n' \
        "$wait_s" "$poll" "$err" >&2
      announced=1
    fi
    # Holder already left the path: retry now so a release inside the budget
    # is observed on this loop, not after a full poll sleep.
    if [ ! -e "$lock_dir" ]; then
      continue
    fi
    sleep "$poll"
  done
}

safe_upgrade_owner_lock_release() {
  local lock_dir="$1" token="$2" held="${3:-0}" current_token staging
  [ "$held" = "1" ] || return 0
  [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 0
  current_token="$(sed -n 's/^token=//p' "$lock_dir/owner" 2>/dev/null | head -1)"
  [ "$current_token" = "$token" ] || return 0
  # Rename first so a waiter never sees a half-deleted dir that still looks
  # like a live owner (pid gone, owner gone, rmdir not yet). mkdir on the
  # original path can succeed as soon as the rename lands.
  staging="${lock_dir}.releasing.${token}.$$"
  if ! mv "$lock_dir" "$staging" 2>/dev/null; then
    return 1
  fi
  rm -f "$staging/pid" "$staging/owner"
  rmdir "$staging" 2>/dev/null || rm -rf "$staging"
  return 0
}
