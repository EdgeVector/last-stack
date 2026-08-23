#!/usr/bin/env bash
# Unit tests for the safe-upgrade DEV photograph-stamp gate (Tom 2026-08-19).
# Drives the shipped gate script and the driver's --check-dev-stamp path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GATE="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-stamp-gate.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$GATE" ] || { echo "FAIL: missing $GATE" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
[ -x "$GATE" ] || { echo "FAIL: gate not executable: $GATE" >&2; exit 1; }
bash -n "$GATE"
bash -n "$DRIVER"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/dev-photograph-stamp-gate.sh
. "$GATE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dev-stamp-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PRIMARY="$TMP/primary-home"
EPHEM="$TMP/ephemeral-home"
mkdir -p "$PRIMARY" "$EPHEM"
PROD_API="https://jdsx4ixk2i.execute-api.us-east-1.amazonaws.com"
DEV_API="https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com"

dev_stamp_api_is_prod "$PROD_API" \
  || { echo "FAIL: prod host should flag" >&2; exit 1; }
dev_stamp_api_is_prod "$DEV_API" \
  && { echo "FAIL: DEV host must not flag as prod" >&2; exit 1; }
dev_stamp_api_is_dev "$DEV_API" \
  || { echo "FAIL: DEV host should match" >&2; exit 1; }
dev_stamp_api_is_dev "$PROD_API" \
  && { echo "FAIL: prod host must not match DEV" >&2; exit 1; }

# Missing receipt → refuse
export LASTDB_HOME="$PRIMARY"
export LASTDB_DEV_STAMP_RECEIPT="$TMP/missing.receipt"
set +e
OUT="$(assert_dev_photograph_stamp_ok "$TMP/missing.receipt" "$PRIMARY" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: missing receipt must refuse; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'RED:' || { echo "FAIL: expected RED: line; out=$OUT" >&2; exit 1; }

# Prod api_url cannot be written GREEN
write_dev_stamp_receipt "$TMP/prod.receipt" GREEN "$PROD_API" "$EPHEM" "$PRIMARY" 3
grep -q '^verdict=RED$' "$TMP/prod.receipt" \
  || { echo "FAIL: write_dev_stamp_receipt must not stamp GREEN on prod api" >&2; exit 1; }
set +e
OUT="$(assert_dev_photograph_stamp_ok "$TMP/prod.receipt" "$PRIMARY" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: prod receipt must refuse live; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'production backup host' \
  || { echo "FAIL: expected production-host reason; out=$OUT" >&2; exit 1; }

# Live home as stamp home → refuse
write_dev_stamp_receipt "$TMP/live.receipt" GREEN "$DEV_API" "$PRIMARY" "$PRIMARY" 2
set +e
OUT="$(assert_dev_photograph_stamp_ok "$TMP/live.receipt" "$PRIMARY" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: live-home stamp must refuse; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'live primary' \
  || { echo "FAIL: expected live-primary reason; out=$OUT" >&2; exit 1; }

# GREEN DEV receipt on ephemeral home → allow
write_dev_stamp_receipt "$TMP/green.receipt" GREEN "$DEV_API" "$EPHEM" "$PRIMARY" 9
set +e
OUT="$(assert_dev_photograph_stamp_ok "$TMP/green.receipt" "$PRIMARY" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: GREEN DEV receipt should allow; out=$OUT" >&2; exit 1; }

# Driver --check-dev-stamp is the real refuse/allow path (not a reimplementation)
grep -q 'dev-photograph-stamp-gate.sh' "$DRIVER" \
  || { echo "FAIL: driver must source dev-photograph-stamp-gate.sh" >&2; exit 1; }
grep -q 'assert_dev_photograph_stamp_ok' "$DRIVER" \
  || { echo "FAIL: driver must call assert_dev_photograph_stamp_ok" >&2; exit 1; }
grep -q -- '--check-dev-stamp' "$DRIVER" \
  || { echo "FAIL: driver must expose --check-dev-stamp" >&2; exit 1; }

export LASTDB_DEV_STAMP_RECEIPT="$TMP/missing.receipt"
set +e
OUT="$("$DRIVER" --check-dev-stamp 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: driver --check-dev-stamp must refuse missing stamp; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'VERDICT: RED' \
  || { echo "FAIL: driver missing stamp must print VERDICT: RED; out=$OUT" >&2; exit 1; }

export LASTDB_DEV_STAMP_RECEIPT="$TMP/green.receipt"
set +e
OUT="$("$DRIVER" --check-dev-stamp 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: driver --check-dev-stamp must allow GREEN DEV stamp; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'VERDICT: GREEN' \
  || { echo "FAIL: driver GREEN stamp must print VERDICT: GREEN; out=$OUT" >&2; exit 1; }

# Skill SOP words
grep -q 'ephemeral/CoW' "$SKILL_MD" \
  || { echo "FAIL: SKILL.md must name ephemeral/CoW" >&2; exit 1; }
grep -q 'DEV' "$SKILL_MD" \
  || { echo "FAIL: SKILL.md must name DEV photograph upload" >&2; exit 1; }
grep -qi 'photograph' "$SKILL_MD" \
  || { echo "FAIL: SKILL.md must name photograph stamp" >&2; exit 1; }
grep -q 'production backup' "$SKILL_MD" \
  || { echo "FAIL: SKILL.md must forbid the primary production backup home" >&2; exit 1; }

echo "OK: lastdb-safe-upgrade DEV photograph-stamp gate"
