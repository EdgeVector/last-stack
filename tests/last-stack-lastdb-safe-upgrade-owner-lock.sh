#!/usr/bin/env bash
# Regression: the complete safe-upgrade process has one host-wide owner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LOCK_HELPER="$ROOT/skills/lastdb-safe-upgrade/scripts/owner-lock.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"

bash -n "$LOCK_HELPER"
bash -n "$DRIVER"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/owner-lock.sh
. "$LOCK_HELPER"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-owner-lock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/lastdb-safe-upgrade-owner-test.lock.d"
TOKEN_ONE="owner-one"
TOKEN_TWO="owner-two"

safe_upgrade_owner_lock_acquire "$LOCK_DIR" "$TOKEN_ONE" "$$" "/tmp/candidate-one" "probe-only"
grep -q "^token=$TOKEN_ONE$" "$LOCK_DIR/owner"
grep -q '^mode=probe-only$' "$LOCK_DIR/owner"

if safe_upgrade_owner_lock_acquire "$LOCK_DIR" "$TOKEN_TWO" "$$" "/tmp/candidate-two" "live" 2>"$TMP/overlap.err"; then
  echo "FAIL: a second owner acquired an active lock" >&2
  exit 1
fi
grep -q 'owner lock active' "$TMP/overlap.err"

# A non-owner cannot release the active owner's lock.
safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_TWO" 1
[ -d "$LOCK_DIR" ] || { echo "FAIL: a non-owner released the lock" >&2; exit 1; }

safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_ONE" 1
[ ! -e "$LOCK_DIR" ] || { echo "FAIL: the owner did not release the lock" >&2; exit 1; }

# A later process can acquire after a normal owner exit.
safe_upgrade_owner_lock_acquire "$LOCK_DIR" "$TOKEN_TWO" "$$" "/tmp/candidate-two" "live"
safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_TWO" 1

# A dead owner is quarantined before a new owner enters.
mkdir "$LOCK_DIR"
printf '99999999\n' >"$LOCK_DIR/pid"
{
  printf 'pid=99999999\n'
  printf 'token=dead-owner\n'
} >"$LOCK_DIR/owner"
safe_upgrade_owner_lock_acquire "$LOCK_DIR" "$TOKEN_ONE" "$$" "/tmp/candidate-three" "probe-only"
grep -q "^token=$TOKEN_ONE$" "$LOCK_DIR/owner"
safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_ONE" 1

grep -q 'owner-lock.sh' "$DRIVER"
grep -q 'another LastDB safe-upgrade process owns the host-wide safety lane' "$DRIVER"

echo "PASS last-stack-lastdb-safe-upgrade-owner-lock"
