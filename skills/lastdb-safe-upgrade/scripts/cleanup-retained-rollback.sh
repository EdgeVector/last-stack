#!/usr/bin/env bash
# Release one retained RED probe rollback point without starting an upgrade.
# A check is read-only. --execute deletes only the named point after every gate.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-retained-rollback.sh --point ABSOLUTE_PATH \
  --expect-primary-pid PID --expect-retained-at UTC_TIMESTAMP [--execute]

The default checks the point without deleting it. --execute releases that
exact point. The primary daemon must still be the process that ran before
the point was created. No safe-upgrade owner or probe may be active.

Set LASTDB_ROLLBACK_ROOT to the point's parent when it differs from this
shell's TMPDIR default. No candidate, probe, install, or restart runs.
EOF
}

point=""
expected_pid=""
expected_retained_at=""
execute=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --point|--expect-primary-pid|--expect-retained-at)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --point) point="$2" ;;
        --expect-primary-pid) expected_pid="$2" ;;
        --expect-retained-at) expected_retained_at="$2" ;;
      esac
      shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$point" ] && [ -n "$expected_pid" ] && [ -n "$expected_retained_at" ] \
  || { usage >&2; exit 2; }
case "$point" in /*) ;; *) die "point path must be absolute" ;; esac
case "$expected_pid" in ""|*[!0-9]*) die "expected primary PID must be numeric" ;; esac
case "$expected_retained_at" in
  ????-??-??T??:??:??Z) ;;
  *) die "expected retained_at must be UTC ISO seconds" ;;
esac

uid="$(id -u)"
home_real="$(cd "$HOME" && pwd -P)"
default_tmp="${TMPDIR:-/tmp}"
case "$(cd "$default_tmp" 2>/dev/null && pwd -P || printf '%s' "$default_tmp")" in
  "$home_real"|"$home_real"/*) default_tmp=/tmp ;;
esac
root="${LASTDB_ROLLBACK_ROOT:-${LASTDB_BACKUP_ROOT:-$default_tmp/lastdb-safe-upgrade-rollback-$uid}}"
primary_home="${LASTDB_HOME:-$HOME/.lastdb}"
owner_lock="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR:-/tmp/lastdb-safe-upgrade-owner-$uid.lock.d}"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=skills/lastdb-safe-upgrade/scripts/owner-lock.sh
. "$script_dir/owner-lock.sh"

owned_by_user() {
  local owner
  if stat --version >/dev/null 2>&1; then
    owner="$(stat -c %u "$1")"
  else
    owner="$(stat -f %u "$1")"
  fi
  [ "$owner" = "$uid" ]
}

to_epoch_utc() {
  local format="$1" value="$2"
  if date --version >/dev/null 2>&1; then
    date -u -d "$value" +%s
  else
    date -j -u -f "$format" "$value" +%s
  fi
}

to_epoch_local_start() {
  local value="$1"
  if date --version >/dev/null 2>&1; then
    date -d "$value" +%s
  else
    date -j -f '%a %b %e %T %Y' "$value" +%s
  fi
}

# The owner lock covers the whole official probe and cutover. Fail at once if
# another owner holds it. The helper never calls the probe or cutover driver.
token="$$.$RANDOM.$(date +%s)"
held=0
release_lock() {
  safe_upgrade_owner_lock_release "$owner_lock" "$token" "$held" \
    || printf 'WARN: owner lock release failed: %s\n' "$owner_lock" >&2
}
trap release_lock EXIT
LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=0 \
  safe_upgrade_owner_lock_acquire_wait "$owner_lock" "$token" "$$" "$point" "rollback-cleanup" \
  || die "a safe-upgrade owner is active; no cleanup ran"
held=1

[ -d "$root" ] && [ ! -L "$root" ] || die "rollback root is missing or a symlink"
root_real="$(cd "$root" && pwd -P)"
case "$root_real" in
  "$home_real"|"$home_real"/*) die "rollback root must be outside HOME" ;;
  /tmp/*|/private/tmp/*|/var/folders/*/T/*|/private/var/folders/*/T/*) ;;
  *) die "rollback root is outside the system temporary directory" ;;
esac
[ "$(basename "$root_real")" = "lastdb-safe-upgrade-rollback-$uid" ] \
  || die "rollback root name does not match this user"
owned_by_user "$root_real" || die "rollback root belongs to another user"

[ -d "$point" ] && [ ! -L "$point" ] || die "point is missing or a symlink"
point_real="$(cd "$point" && pwd -P)"
[ "$(dirname "$point_real")" = "$root_real" ] \
  || die "point is not a direct child of the rollback root"
owned_by_user "$point_real" || die "point belongs to another user"
base="$(basename "$point_real")"
case "$base" in pre-*-from-*) ;; *) die "point name is not a safe-upgrade rollback" ;; esac
clone_stamp="$(printf '%s\n' "$base" | sed -nE 's/^pre-.*-from-.*-([0-9]{8}T[0-9]{6}Z)$/\1/p')"
from_build="$(printf '%s\n' "$base" | sed -nE 's/^pre-.*-from-(.*)-[0-9]{8}T[0-9]{6}Z$/\1/p')"
[ -n "$clone_stamp" ] && [ -n "$from_build" ] \
  || die "point name lacks an exact source build and UTC clone time"
clone_epoch="$(to_epoch_utc '%Y%m%dT%H%M%SZ' "$clone_stamp" 2>/dev/null)" \
  || die "point clone time is invalid"
retained_epoch="$(to_epoch_utc '%Y-%m-%dT%H:%M:%SZ' "$expected_retained_at" 2>/dev/null)" \
  || die "expected retained_at is invalid"
[ "$retained_epoch" -ge "$clone_epoch" ] \
  || die "retention time predates the rollback point"
[ "$retained_epoch" -le "$(date +%s)" ] \
  || die "retention time is in the future"

marker="$point_real/.safe-upgrade/retention"
[ -f "$marker" ] && [ ! -L "$marker" ] || die "retention marker is missing or a symlink"
owned_by_user "$marker" || die "retention marker belongs to another user"
ttl="$(sed -n 's/^ttl_hours=//p' "$marker")"
case "$ttl" in ""|*[!0-9]*) die "retention TTL is invalid" ;; esac
[ "$ttl" -gt 0 ] && [ "$ttl" -le 168 ] || die "retention TTL is outside 1..168 hours"
cleanup_owner="$(sed -n 's/^cleanup_owner=//p' "$marker")"
case "$cleanup_owner" in
  explicit-retained-point-helper|next-lastdb-safe-upgrade-run) ;;
  *) die "retention cleanup owner is invalid" ;;
esac
cmp -s "$marker" <(printf 'retained_at=%s\nttl_hours=%s\ncleanup_owner=%s\n' \
  "$expected_retained_at" "$ttl" "$cleanup_owner") \
  || die "retention marker differs from the expected RED marker"

[ -f "$point_real/identity.key" ] && [ -d "$point_real/data" ] \
  || die "rollback point lacks the primary home essentials"
[ -e "$point_real/data/db" ] || [ -d "$point_real/data/data" ] \
  || [ -d "$point_real/data/laststore" ] \
  || die "rollback point lacks the data store"
[ -d "$primary_home/data" ] || die "primary data directory is missing"
live_data="$(cd "$primary_home/data" && pwd -P)"
point_data="$(cd "$point_real/data" && pwd -P)"
[ "$point_data" != "$live_data" ] || die "rollback data aliases the live primary"

check_live_state() {
  local status active_pid active_build installed_build started started_epoch processes
  status="$(lastdb status)" || die "primary status over the Unix socket is unavailable"
  active_pid="$(printf '%s\n' "$status" | sed -nE 's/^Uptime:.*\(pid ([0-9]+),.*/\1/p' | head -1)"
  active_build="$(printf '%s\n' "$status" | sed -nE 's/^Build:[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)"
  [ "$active_pid" = "$expected_pid" ] && [ "$active_build" = "$from_build" ] \
    || die "primary PID or build changed since the RED probe"
  started="$(ps -p "$active_pid" -o lstart=)" || die "cannot read primary start time"
  started_epoch="$(to_epoch_local_start "$started" 2>/dev/null)" \
    || die "cannot parse primary start time"
  [ "$started_epoch" -lt "$clone_epoch" ] \
    || die "primary started after the rollback point was created"
  installed_bin="${LASTDB_SIDEBIN_DIR:-$primary_home/bin-with-upload-cap}/lastdbd"
  [ -x "$installed_bin" ] || die "installed primary daemon is missing"
  installed_build="$("$installed_bin" --version | awk '{print $NF}')" \
    || die "cannot read installed primary build"
  [ "$installed_build" = "$from_build" ] \
    || die "installed daemon differs from the pre-probe build"
  processes="$(ps -axo pid=,command=)" || die "cannot inspect active processes"
  if printf '%s\n' "$processes" | grep -E 'lastdbd.*(lastdb-safe-upgrade\.|lastdb-safe-upgrade-rollback-)' >/dev/null; then
    die "a safe-upgrade probe or rollback node is active"
  fi
}

check_live_state
printf 'READY: exact retained point is safe to release: %s\n' "$point_real"
printf 'PRIMARY: pid=%s build=%s started before point creation\n' "$expected_pid" "$from_build"
if [ "$execute" -eq 0 ]; then
  printf 'CHECK ONLY: add --execute to release this point.\n'
  exit 0
fi

# Recheck the live process and marker just before the only destructive call.
check_live_state
cmp -s "$marker" <(printf 'retained_at=%s\nttl_hours=%s\ncleanup_owner=%s\n' \
  "$expected_retained_at" "$ttl" "$cleanup_owner") \
  || die "retention marker changed before release"
[ -d "$point_real" ] && [ ! -L "$point_real" ] \
  || die "rollback point changed before release"
owned_by_user "$point_real" || die "rollback point owner changed before release"
[ "$(cd "$point_real" && pwd -P)" = "$root_real/$base" ] \
  || die "rollback point path changed before release"
rm -rf "$point_real"
printf 'RELEASED: %s\n' "$point_real"
