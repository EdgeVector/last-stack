#!/usr/bin/env bash
# Fixture test: after GREEN cutover retention prunes excess routine pre-* trees
# while leaving BROKEN-*/pre-repair-*/hand names and the current-run backup alone.
# Card: lastdb-safe-upgrade-backups-have-no-retention-policy-20260817
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
pin_py="$ROOT/skills/lastdb-safe-upgrade/scripts/backup-pin-bytes.py"

[ -f "$driver" ] || { echo "FAIL: missing driver $driver" >&2; exit 1; }
[ -f "$pin_py" ] || { echo "FAIL: missing pin estimator $pin_py" >&2; exit 1; }
bash -n "$driver"
python3 -m py_compile "$pin_py"

# Static presence of policy hooks
grep -q '^is_routine_pre_upgrade_backup()' "$driver" || {
  echo "FAIL: driver must define is_routine_pre_upgrade_backup" >&2
  exit 1
}
grep -q '^prune_excess_pre_upgrade_backups()' "$driver" || {
  echo "FAIL: driver must define prune_excess_pre_upgrade_backups" >&2
  exit 1
}
grep -q '^report_backup_root_inventory()' "$driver" || {
  echo "FAIL: driver must define report_backup_root_inventory" >&2
  exit 1
}
grep -q 'LASTDB_BACKUP_KEEP' "$driver" || {
  echo "FAIL: driver must honor LASTDB_BACKUP_KEEP" >&2
  exit 1
}
grep -q 'prune_excess_pre_upgrade_backups "\$BACKUP"' "$driver" || {
  echo "FAIL: GREEN path must call prune_excess_pre_upgrade_backups with current BACKUP" >&2
  exit 1
}
grep -q 'report_backup_root_inventory' "$driver" || {
  echo "FAIL: preflight must call report_backup_root_inventory" >&2
  exit 1
}
# Policy must not prune non-routine names via a broad pre-* glob delete.
if grep -nE 'rm -rf "\$BACKUP_ROOT"/pre-\*' "$driver" >/dev/null; then
  echo "FAIL: must not rm -rf BACKUP_ROOT/pre-* (too broad)" >&2
  exit 1
fi

# Extract only the retention helpers (stop before the next unrelated function).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-backup-retention.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk '
  /^is_routine_pre_upgrade_backup\(\)/ { grab=1 }
  grab { print }
  grab && /^rss_mb_of_pid\(\)/ { exit }
' "$driver" >"$TMP/fns.sh"

# Drop the rss_mb_of_pid header line that awk may include as the exit sentinel.
# (we exit when we *see* it, after printing — strip it)
grep -v '^rss_mb_of_pid()' "$TMP/fns.sh" >"$TMP/fns2.sh" || true
mv "$TMP/fns2.sh" "$TMP/fns.sh"

grep -q '^is_routine_pre_upgrade_backup()' "$TMP/fns.sh" || {
  echo "FAIL: could not extract is_routine_pre_upgrade_backup" >&2
  exit 1
}
grep -q '^prune_excess_pre_upgrade_backups()' "$TMP/fns.sh" || {
  echo "FAIL: could not extract prune_excess_pre_upgrade_backups" >&2
  exit 1
}

# --- Fixture layout ----------------------------------------------------------
# 4 routine pre-* trees (timestamps increasing), current = newest.
# Non-routine: BROKEN-postcutover-*, pre-repair-*, hand-named bystander.
# KEEP=2 → keep 2 prior + current = 3 routine; prune 1 oldest routine.
# Non-routine must remain.

BACKUP_ROOT="$TMP/backups"
PRIMARY_HOME="$TMP/primary"
mkdir -p "$PRIMARY_HOME/data/data"
: >"$PRIMARY_HOME/identity.key"

mk_tree() {
  local name="$1"
  mkdir -p "$BACKUP_ROOT/$name/data/data"
  : >"$BACKUP_ROOT/$name/identity.key"
  # Distinct (size, mtime) identity per tree so pin estimator has work.
  printf 'payload-%s\n' "$name" >"$BACKUP_ROOT/$name/data/data/blob.bin"
}

mk_tree "pre-0.23.3-A-from-0.23.3-Z-20260810T010000Z"   # oldest → prune
mk_tree "pre-0.23.3-B-from-0.23.3-A-20260811T020000Z"   # keep prior
mk_tree "pre-0.23.3-C-from-0.23.3-B-20260812T030000Z"   # keep prior
CURRENT="pre-0.23.3-D-from-0.23.3-C-20260813T040000Z"
mk_tree "$CURRENT"                                       # protect (current run)
mk_tree "BROKEN-postcutover-20260816T054636Z"
mk_tree "pre-repair-dangling-tips-20260816T152131Z"
mk_tree "hand-named-bystander"

# Name that looks pre-* but lacks -from- must not be treated as routine.
mk_tree "pre-not-a-routine-backup-20260816T000000Z"

log() { printf '[test] %s\n' "$*"; }
warn() { printf '[test-warn] %s\n' "$*" >&2; }
die() { printf '[test] ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
. "$TMP/fns.sh"

# Classifier checks
is_routine_pre_upgrade_backup "pre-0.23.3-A-from-0.23.3-Z-20260810T010000Z" || {
  echo "FAIL: routine name should match" >&2
  exit 1
}
is_routine_pre_upgrade_backup "BROKEN-postcutover-20260816T054636Z" && {
  echo "FAIL: BROKEN tree must not match routine" >&2
  exit 1
}
is_routine_pre_upgrade_backup "pre-repair-dangling-tips-20260816T152131Z" && {
  echo "FAIL: pre-repair tree must not match routine" >&2
  exit 1
}
is_routine_pre_upgrade_backup "pre-not-a-routine-backup-20260816T000000Z" && {
  echo "FAIL: pre-* without -from- must not match" >&2
  exit 1
}
is_routine_pre_upgrade_backup "hand-named-bystander" && {
  echo "FAIL: bystander must not match" >&2
  exit 1
}

export LASTDB_BACKUP_KEEP=2
export SAFE_UPGRADE_SCRIPTS_DIR="$ROOT/skills/lastdb-safe-upgrade/scripts"
BACKUP="$BACKUP_ROOT/$CURRENT"
prune_excess_pre_upgrade_backups "$BACKUP"

# Assert: oldest routine gone; 3 routine remain; non-routine intact
[ ! -d "$BACKUP_ROOT/pre-0.23.3-A-from-0.23.3-Z-20260810T010000Z" ] || {
  echo "FAIL: oldest routine pre-* should have been pruned" >&2
  exit 1
}
for keep_name in \
  "pre-0.23.3-B-from-0.23.3-A-20260811T020000Z" \
  "pre-0.23.3-C-from-0.23.3-B-20260812T030000Z" \
  "$CURRENT" \
  "BROKEN-postcutover-20260816T054636Z" \
  "pre-repair-dangling-tips-20260816T152131Z" \
  "hand-named-bystander" \
  "pre-not-a-routine-backup-20260816T000000Z"
do
  [ -d "$BACKUP_ROOT/$keep_name" ] || {
    echo "FAIL: expected kept tree missing: $keep_name" >&2
    exit 1
  }
done

# KEEP=0 must not prune further
export LASTDB_BACKUP_KEEP=0
# Recreate a would-be prune target and ensure it survives
mk_tree "pre-0.23.3-E-from-0.23.3-D-20260814T050000Z"
prune_excess_pre_upgrade_backups "$BACKUP"
[ -d "$BACKUP_ROOT/pre-0.23.3-E-from-0.23.3-D-20260814T050000Z" ] || {
  echo "FAIL: LASTDB_BACKUP_KEEP=0 must not prune" >&2
  exit 1
}

# Pin estimator runs and prints pinned_bytes=
set +e
PIN_OUT="$(python3 "$pin_py" "$PRIMARY_HOME" "$BACKUP_ROOT" 2>&1)"
PIN_RC=$?
set -e
[ "$PIN_RC" -eq 0 ] || {
  echo "FAIL: backup-pin-bytes.py rc=$PIN_RC out=$PIN_OUT" >&2
  exit 1
}
echo "$PIN_OUT" | grep -q 'pinned_bytes=' || {
  echo "FAIL: pin estimator missing pinned_bytes=; out=$PIN_OUT" >&2
  exit 1
}

echo "PASS last-stack-safe-upgrade-backup-retention"
