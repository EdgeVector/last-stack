#!/usr/bin/env bash
# Fixture tests for the safe-upgrade probe-copy guards.
# The probe node runs on an APFS clone of the primary home. These cases keep
# the clone, and the conflict-stamp flag, away from the primary. This test
# does not start lastdbd and does not read the primary home.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUARDS="$ROOT/skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
ENVSH="$ROOT/skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$GUARDS" ] || { echo "FAIL: missing $GUARDS" >&2; exit 1; }
bash -n "$GUARDS"
bash -n "$DRIVER"
bash -n "$ENVSH"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh
. "$GUARDS"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh
. "$ENVSH"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/probe-copy-guards.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- stamp stays on the copy ------------------------------------------------
probe_stamp_env_allowed ephemeral-copy 1 || fail "copy may set the stamp flag"
probe_stamp_env_allowed primary "" || fail "unset primary stamp flag is allowed"
probe_stamp_env_allowed primary 0 || fail "primary 0 is allowed"
if probe_stamp_env_allowed primary 1; then
  fail "primary must not carry LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1"
fi
probe_copy_is_not_primary /tmp/probe-copy /tmp/probe-primary \
  || fail "distinct copy and primary must pass"
if probe_copy_is_not_primary /tmp/probe-primary /tmp/probe-primary; then
  fail "copy must not be the primary home"
fi
if probe_copy_is_not_primary /tmp/probe-primary/child /tmp/probe-primary; then
  fail "copy inside the primary home must fail"
fi
mkdir -p "$TMP/primary/child" "$TMP/elsewhere"
ln -s "$TMP/primary" "$TMP/primary-link"
if probe_copy_is_not_primary "$TMP/primary/" "$TMP/primary"; then
  fail "a trailing slash must not make the primary path look distinct"
fi
if probe_copy_is_not_primary "$TMP/primary/child" "$TMP/primary/"; then
  fail "a trailing slash on the primary must still reject a child"
fi
if probe_copy_is_not_primary "$TMP/primary-link" "$TMP/primary"; then
  fail "a symlink to the primary home must fail"
fi
if probe_copy_is_not_primary "$TMP/elsewhere" "$TMP/primary"; then
  :
else
  fail "a real directory outside the primary must pass"
fi
if grep -n 'probe_copy_is_not_primary' "$DRIVER" | grep -q 'rm -rf'; then
  fail "a failed primary-path check must not sit on an rm -rf line"
fi
awk '
  /if ! probe_copy_is_not_primary "\$c_copy"/ { c=1; n=0 }
  /if ! probe_copy_is_not_primary "\$b_copy"/ { c=1; n=0 }
  c { n++; if ($0 ~ /rm -rf/) bad=1 }
  c && /^  fi$/ { c=0 }
  END { if (bad) exit 1 }
' "$DRIVER" || fail "the primary-path failure arm must not delete the path"
grep -q 'remove_probe_copy' "$DRIVER" || fail "driver must delete probe copies through remove_probe_copy"
grep -q -- '-u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_DATA_DIR' "$DRIVER" \
  || fail "the probe env must clear LASTDB_HOME, FOLDDB_HOME, and LASTDB_DATA_DIR"

plist="$TMP/live.plist"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:LASTDB_HASH_GROUP_WARM_BYTES string 4294967296' "$plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:LASTDB_BUILD_CONFLICT_STAMP_ON_COPY string 1' "$plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:LASTDB_HOME string /tmp/not-a-home' "$plist" >/dev/null
mirror="$(live_lastdb_env_pairs "$plist")"
echo "$mirror" | grep -q 'LASTDB_HASH_GROUP_WARM_BYTES=4294967296' \
  || fail "env mirror must keep an ordinary LASTDB key; out=$mirror"
echo "$mirror" | grep -q 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY' \
  && fail "env mirror must not copy the stamp flag; out=$mirror"
echo "$mirror" | grep -q 'LASTDB_HOME' \
  && fail "env mirror must still drop LASTDB_HOME; out=$mirror"
stamp_val="$(probe_plist_stamp_value "$plist")"
if probe_stamp_env_allowed primary "$stamp_val"; then
  fail "plist stamp value must be rejected for the primary"
fi


# --- driver wiring -----------------------------------------------------------
grep -q '\. "$_SCRIPT_DIR/probe-copy-guards.sh"' "$DRIVER" || fail "driver must source probe-copy-guards.sh"
[ "$(grep -c 'stamp_env="LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1"' "$DRIVER")" -eq 1 ] \
  || fail "stamp flag must be assigned once"
awk '
  /^start_probe_node\(\)/ { p=1 }
  p { print }
  p && /^}$/ { exit }
' "$DRIVER" >"$TMP/start.sh"
grep -q 'label" = "candidate"' "$TMP/start.sh" \
  || grep -q '\[ "$label" = "candidate" \]' "$TMP/start.sh" \
  || fail "stamp flag must be gated on the candidate label"
grep -q 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1' "$TMP/start.sh" \
  || fail "stamp flag assignment must live in start_probe_node"
if grep 'PlistBuddy' "$DRIVER" | grep -q 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY'; then
  fail "driver must not write the stamp flag into a plist"
fi
grep -q 'probe_stamp_env_allowed primary' "$DRIVER" \
  || fail "driver must reject the stamp flag on the primary"
grep -q 'probe_copy_is_not_primary' "$DRIVER" \
  || fail "driver must refuse a copy that is the primary home"

# --- the byte footprint bar is gone -----------------------------------------
# Tom, 2026-10-04: eviction is measured in keys, so a GiB footprint bar does
# not belong in the gate. The key-cap bar is the eviction proof.
[ ! -e "$ROOT/skills/lastdb-safe-upgrade/scripts/footprint-bar-checks.sh" ] \
  || fail "footprint-bar-checks.sh must stay removed"
if grep -q 'footprint_bar_eval\|footprint_collect_upgrade_gate\|FOOTPRINT:' "$DRIVER"; then
  fail "driver must not run or print a byte footprint bar"
fi
grep -q 'key_cap_bar_eval "$KC_PROOF"' "$DRIVER" || fail "driver must score the key-cap bar"
grep -q 'KEYCAP:' "$DRIVER" || fail "driver must print the KEYCAP receipt"
grep -q 'LASTDB_RESIDENT_KEY_CAP' "$SKILL_MD" || fail "SKILL.md must name the key-cap override"

echo "ok: probe copy guards fixture"
