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
# The driver must use the wait-aware acquire so a loom re-dispatch that finds
# an earlier attempt's live lock waits for the lane instead of going RED.
grep -q 'safe_upgrade_owner_lock_acquire_wait ' "$DRIVER"

# --- acquire_wait ------------------------------------------------------------

# Default (wait 0): an active lock still fails at once.
safe_upgrade_owner_lock_acquire "$LOCK_DIR" "$TOKEN_ONE" "$$" "/tmp/candidate-one" "probe-only"
if safe_upgrade_owner_lock_acquire_wait "$LOCK_DIR" "$TOKEN_TWO" "$$" "/tmp/candidate-two" "live" 2>"$TMP/wait0.err"; then
  echo "FAIL: acquire_wait with wait=0 acquired an active lock" >&2
  exit 1
fi
grep -q 'owner lock active' "$TMP/wait0.err"

# A bounded wait outlives a holder that releases: acquire_wait must succeed.
(
  sleep 2
  safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_ONE" 1
) &
releaser=$!
if ! LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=30 LASTDB_SAFE_UPGRADE_OWNER_LOCK_POLL_S=1 \
    safe_upgrade_owner_lock_acquire_wait "$LOCK_DIR" "$TOKEN_TWO" "$$" "/tmp/candidate-two" "live" 2>"$TMP/waited.err"; then
  echo "FAIL: acquire_wait did not acquire after the holder released" >&2
  exit 1
fi
wait "$releaser"
grep -q 'owner lock busy — waiting' "$TMP/waited.err"
grep -q "^token=$TOKEN_TWO$" "$LOCK_DIR/owner"

# An expired wait fails and names the exhausted budget.
if LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=2 LASTDB_SAFE_UPGRADE_OWNER_LOCK_POLL_S=1 \
    safe_upgrade_owner_lock_acquire_wait "$LOCK_DIR" "$TOKEN_ONE" "$$" "/tmp/candidate-one" "live" 2>"$TMP/expired.err"; then
  echo "FAIL: acquire_wait acquired a lock its holder never released" >&2
  exit 1
fi
grep -q 'owner lock still busy after 2s wait' "$TMP/expired.err"
safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_TWO" 1

# A non-contention error is not retried, even with a wait budget.
ln -s "$TMP/elsewhere.lock.d" "$TMP/sym.lock.d"
if LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=60 LASTDB_SAFE_UPGRADE_OWNER_LOCK_POLL_S=1 \
    safe_upgrade_owner_lock_acquire_wait "$TMP/sym.lock.d" "$TOKEN_ONE" "$$" "/tmp/candidate-one" "live" 2>"$TMP/sym.err"; then
  echo "FAIL: acquire_wait acquired through a symlink lock path" >&2
  exit 1
fi
grep -q 'must not be a symlink' "$TMP/sym.err"
if grep -q 'waiting' "$TMP/sym.err"; then
  echo "FAIL: acquire_wait retried a non-contention error" >&2
  exit 1
fi

echo "PASS last-stack-lastdb-safe-upgrade-owner-lock"
