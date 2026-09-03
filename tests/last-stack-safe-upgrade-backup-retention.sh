#!/usr/bin/env bash
# Regression: safe-upgrade owns one ephemeral rollback point, releases GREEN,
# and retains RED with an explicit TTL/cleanup owner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
bash -n "$driver"

grep -q '^prepare_rollback_root()' "$driver"
grep -q '^newest_routine_rollback_point()' "$driver"
grep -q '^release_rollback_point()' "$driver"
grep -q '^retain_rollback_point()' "$driver"
grep -q 'cleanup_owner=next-lastdb-safe-upgrade-run' "$driver"
grep -q 'ROLLBACK_TTL_HOURS="${LASTDB_ROLLBACK_TTL_HOURS:-24}"' "$driver"
grep -q 'release_rollback_point' "$driver"
grep -q 'on_driver_end()' "$driver"
grep -q 'DRIVER_ENDED_STEP' "$driver"
grep -q 'kept newest point' "$driver"

if grep -q '\$HOME/.lastdb-backups\|\$HOME/.lastdb-test-copies\|LASTDB_BACKUP_KEEP' "$driver"; then
  echo "FAIL: driver still defaults to persistent HOME copies/retention" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-rollback-lifecycle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk '
  /^release_rollback_point\(\)/ { grab=1 }
  grab { print }
  grab && /^backup_essentials_ok\(\)/ { exit }
' "$driver" | grep -v '^backup_essentials_ok()' >"$TMP/lifecycle.sh"
awk '
  /^backup_essentials_ok\(\)/ { grab=1 }
  grab { print }
  grab && /^rss_mb_of_pid\(\)/ { exit }
' "$driver" | grep -v '^rss_mb_of_pid()' >"$TMP/rollback.sh"

HOME="$TMP/home"
PRIMARY_HOME="$TMP/primary"
ROLLBACK_ROOT="$TMP/rollback"
ROLLBACK_TTL_HOURS=24
BACKUP=""
ROLLBACK_READY=0
WORK=""
mkdir -p "$HOME" "$PRIMARY_HOME/data/data" "$ROLLBACK_ROOT"
: >"$PRIMARY_HOME/identity.key"
log() { printf '[test] %s\n' "$*"; }
warn() { printf '[test-warn] %s\n' "$*" >&2; }
die() { printf '[test] ERROR: %s\n' "$*" >&2; return 1; }
. "$TMP/lifecycle.sh"
. "$TMP/rollback.sh"

older="$ROLLBACK_ROOT/pre-new-from-old-20260817T010203Z"
newer="$ROLLBACK_ROOT/pre-new-from-old-20260818T010203Z"
mkdir -p "$older/data/data" "$newer/data/data" "$ROLLBACK_ROOT/hand-owned"
: >"$older/identity.key"
: >"$newer/identity.key"
prepare_rollback_root
[ ! -e "$older" ] || { echo "FAIL: older routine rollback survived" >&2; exit 1; }
[ -d "$newer" ] || { echo "FAIL: newest rollback point was reclaimed" >&2; exit 1; }
[ -d "$ROLLBACK_ROOT/hand-owned" ] || { echo "FAIL: narrow cleanup removed bystander" >&2; exit 1; }
[ "$(newest_routine_rollback_point)" = "$newer" ] \
  || { echo "FAIL: newest_routine_rollback_point missed $newer" >&2; exit 1; }

BACKUP="$newer"
ROLLBACK_READY=1
retain_rollback_point
grep -q '^ttl_hours=24$' "$BACKUP/.safe-upgrade/retention"
grep -q '^cleanup_owner=next-lastdb-safe-upgrade-run$' "$BACKUP/.safe-upgrade/retention"

# A new run keeps the newest point so a later attempt can reuse it.
prepare_rollback_root
[ -d "$BACKUP" ] || { echo "FAIL: newest rollback point was not kept for reuse" >&2; exit 1; }

# cleanup_work on a driver-ended step must retain, not release, even if EXIT rc=0.
sed -n '/^cleanup_work() {/,/^}/p' "$driver" >"$TMP/cleanup_work.sh"
WORK=""
CUTOVER_LOCK=""
DRIVER_ENDED_STEP=1
ROLLBACK_READY=1
BACKUP="$newer"
# shellcheck source=/dev/null
. "$TMP/cleanup_work.sh"
cleanup_work
[ -d "$newer" ] || { echo "FAIL: driver-ended cleanup removed the newest point" >&2; exit 1; }
[ -f "$newer/.safe-upgrade/retention" ] \
  || { echo "FAIL: driver-ended cleanup did not retain the newest point" >&2; exit 1; }

# SIGTERM (loom drive deadline) must keep the newest point.
kill_dir="$TMP/kill-keep"
ready_fifo="$TMP/killed.ready"
mkdir -p "$kill_dir/data/data"
: >"$kill_dir/identity.key"
mkfifo "$ready_fifo"
cat >"$TMP/killed.sh" <<'SH'
set -u
BACKUP="$1"
ready_fifo="$2"
ROLLBACK_ROOT="$(dirname "$BACKUP")"
ROLLBACK_TTL_HOURS=24
ROLLBACK_READY=1
DRIVER_ENDED_STEP=0
WORK=""
CUTOVER_LOCK=""
OWNER_LOCK_DIR=""
OWNER_LOCK_TOKEN=""
OWNER_LOCK_HELD=0
log() { :; }
warn() { :; }
retain_rollback_point() {
  mkdir -p "$BACKUP/.safe-upgrade"
  printf 'cleanup_owner=next-lastdb-safe-upgrade-run\n' >"$BACKUP/.safe-upgrade/retention"
}
release_rollback_point() { rm -rf "$BACKUP"; ROLLBACK_READY=0; }
cleanup_work() {
  if [ "${ROLLBACK_READY:-0}" -eq 1 ]; then
    retain_rollback_point
  fi
}
on_driver_end() { DRIVER_ENDED_STEP=1; exit 143; }
trap 'on_driver_end' HUP INT TERM
trap cleanup_work EXIT
printf 'ready\n' >"$ready_fifo"
sleep 30
SH
set +e
bash "$TMP/killed.sh" "$kill_dir" "$ready_fifo" >"$TMP/killed.out" 2>"$TMP/killed.err" &
kill_pid=$!
read -t 10 -r _ready <"$ready_fifo" \
  || { echo "FAIL: SIGTERM child did not arm traps" >&2; kill -TERM "$kill_pid" 2>/dev/null || true; exit 1; }
kill -TERM "$kill_pid" 2>/dev/null || true
wait "$kill_pid" 2>/dev/null || true
set -e
[ -d "$kill_dir" ] || { echo "FAIL: SIGTERM cleanup removed the rollback point" >&2; exit 1; }
[ -f "$kill_dir/.safe-upgrade/retention" ] \
  || { echo "FAIL: SIGTERM cleanup did not retain the rollback point" >&2; exit 1; }

BACKUP="$ROLLBACK_ROOT/pre-newer-from-new-20260818T020304Z"
mkdir -p "$BACKUP/data/data"
: >"$BACKUP/identity.key"
ROLLBACK_READY=1
release_rollback_point
[ ! -e "$BACKUP" ] || { echo "FAIL: GREEN release left rollback point" >&2; exit 1; }

echo "PASS last-stack-safe-upgrade-backup-retention"
