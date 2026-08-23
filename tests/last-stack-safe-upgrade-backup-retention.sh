#!/usr/bin/env bash
# Regression: safe-upgrade owns one ephemeral rollback point, releases GREEN,
# and retains RED with an explicit TTL/cleanup owner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
bash -n "$driver"

grep -q '^prepare_rollback_root()' "$driver"
grep -q '^release_rollback_point()' "$driver"
grep -q '^retain_rollback_point()' "$driver"
grep -q 'cleanup_owner=next-lastdb-safe-upgrade-run' "$driver"
grep -q 'ROLLBACK_TTL_HOURS="${LASTDB_ROLLBACK_TTL_HOURS:-24}"' "$driver"
grep -q 'release_rollback_point' "$driver"

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

old="$ROLLBACK_ROOT/pre-new-from-old-20260817T010203Z"
mkdir -p "$old/data/data" "$ROLLBACK_ROOT/hand-owned"
: >"$old/identity.key"
prepare_rollback_root
[ ! -e "$old" ] || { echo "FAIL: previous routine rollback survived" >&2; exit 1; }
[ -d "$ROLLBACK_ROOT/hand-owned" ] || { echo "FAIL: narrow cleanup removed bystander" >&2; exit 1; }

BACKUP="$ROLLBACK_ROOT/pre-new-from-old-20260818T010203Z"
mkdir -p "$BACKUP/data/data"
: >"$BACKUP/identity.key"
ROLLBACK_READY=1
retain_rollback_point
grep -q '^ttl_hours=24$' "$BACKUP/.safe-upgrade/retention"
grep -q '^cleanup_owner=next-lastdb-safe-upgrade-run$' "$BACKUP/.safe-upgrade/retention"

# A new run reclaims the one retained point before it creates another.
prepare_rollback_root
[ ! -e "$BACKUP" ] || { echo "FAIL: retained rollback not reclaimed next run" >&2; exit 1; }

BACKUP="$ROLLBACK_ROOT/pre-newer-from-new-20260818T020304Z"
mkdir -p "$BACKUP/data/data"
: >"$BACKUP/identity.key"
ROLLBACK_READY=1
release_rollback_point
[ ! -e "$BACKUP" ] || { echo "FAIL: GREEN release left rollback point" >&2; exit 1; }

echo "PASS last-stack-safe-upgrade-backup-retention"
