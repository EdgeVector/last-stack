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

dump_acquire_wait_failure() {
  # Shared mutable state for this race is $LOCK_DIR/owner plus the releaser
  # marker. Dump those before the one-line FAIL so a red names its cause
  # (preference-deflake-proof-assert-the-cause-not-the-schedule).
  local releaser_rc="$1"
  printf 'FAIL: acquire_wait did not acquire after the holder released\n' >&2
  printf 'releaser_rc=%s\n' "$releaser_rc" >&2
  if [ -f "$TMP/released" ]; then
    printf 'released_marker=present\n' >&2
  else
    printf 'released_marker=missing\n' >&2
  fi
  printf -- '--- owner ---\n' >&2
  if [ -f "$LOCK_DIR/owner" ]; then
    cat "$LOCK_DIR/owner" >&2
  else
    printf '(missing)\n' >&2
  fi
  printf -- '--- waited.err ---\n' >&2
  if [ -s "$TMP/waited.err" ]; then
    cat "$TMP/waited.err" >&2
  else
    printf '(empty)\n' >&2
  fi
}

# A bounded wait outlives a holder that releases: acquire_wait must succeed.
# Releaser writes a marker after the release call. Assert that marker before
# judging the wait, so a failed release is not reported as a wait miss.
rm -f "$TMP/released" "$TMP/releaser.rc" "$TMP/waited.err"
(
  sleep 2
  rc=0
  safe_upgrade_owner_lock_release "$LOCK_DIR" "$TOKEN_ONE" 1 || rc=$?
  printf '%s\n' "$rc" >"$TMP/releaser.rc"
  : >"$TMP/released"
) &
releaser=$!
LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S=30 LASTDB_SAFE_UPGRADE_OWNER_LOCK_POLL_S=1 \
  safe_upgrade_owner_lock_acquire_wait "$LOCK_DIR" "$TOKEN_TWO" "$$" "/tmp/candidate-two" "live" \
  2>"$TMP/waited.err" &
waiter=$!

release_waited=0
while [ "$release_waited" -lt 30 ]; do
  if [ -f "$TMP/released" ]; then
    break
  fi
  if ! kill -0 "$releaser" 2>/dev/null && [ ! -f "$TMP/released" ]; then
    break
  fi
  sleep 1
  release_waited=$((release_waited + 1))
done

releaser_rc="missing"
if [ -f "$TMP/releaser.rc" ]; then
  releaser_rc="$(cat "$TMP/releaser.rc")"
fi
wait "$releaser" || true

if [ ! -f "$TMP/released" ]; then
  kill "$waiter" 2>/dev/null || true
  wait "$waiter" || true
  dump_acquire_wait_failure "$releaser_rc"
  printf 'FAIL cause: releaser did not write released marker\n' >&2
  exit 1
fi
if [ "$releaser_rc" != "0" ]; then
  kill "$waiter" 2>/dev/null || true
  wait "$waiter" || true
  dump_acquire_wait_failure "$releaser_rc"
  printf 'FAIL cause: release rc=%s\n' "$releaser_rc" >&2
  exit 1
fi

wait_rc=0
wait "$waiter" || wait_rc=$?
if [ "$wait_rc" -ne 0 ]; then
  dump_acquire_wait_failure "$releaser_rc"
  exit 1
fi
grep -q 'owner lock busy — waiting' "$TMP/waited.err"
grep -q "^token=$TOKEN_TWO$" "$LOCK_DIR/owner"

# Cause probe: the dump always names releaser_rc, the owner file, and waited.err.
# Re-introducing the pre-fix one-line FAIL (no dump) makes this block fail.
dump_acquire_wait_failure 7 >"$TMP/dump.out" 2>&1 || true
grep -q 'releaser_rc=7' "$TMP/dump.out"
grep -q 'released_marker=' "$TMP/dump.out"
grep -Fq -- '--- owner ---' "$TMP/dump.out"
grep -Fq -- '--- waited.err ---' "$TMP/dump.out"

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

# Source guards: the wait-failure path must dump owner, releaser rc, and
# waited.err. The driver must retry stale-recovery races and must not use a
# date-or-zero deadline that can expire on the first poll.
grep -q 'dump_acquire_wait_failure' "$0"
grep -q 'releaser_rc=' "$0"
grep -q 'released_marker=' "$0"
grep -Fq -- '--- waited.err ---' "$0"
grep -q 'owner lock changed during stale recovery' "$LOCK_HELPER"
if grep -n 'date +%s 2>/dev/null || echo 0' "$LOCK_HELPER" | grep -q acquire_wait; then
  echo "FAIL: acquire_wait still uses a date-or-zero deadline" >&2
  exit 1
fi
grep -q 'started="$SECONDS"' "$LOCK_HELPER"
grep -q 'mv "$lock_dir" "$staging"' "$LOCK_HELPER"

echo "PASS last-stack-lastdb-safe-upgrade-owner-lock"
