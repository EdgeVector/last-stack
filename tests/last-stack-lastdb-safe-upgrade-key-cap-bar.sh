#!/usr/bin/env bash
# Fixture tests for the safe-upgrade key-cap bar.
# Status JSON only. This test does not start lastdbd and does not read the
# primary home. The sample shape is the one fold f716d2609 serves on
# /api/status (.status.resident.*, plain integers), measured 2026-10-04.
#
# Run one case: bash tests/last-stack-lastdb-safe-upgrade-key-cap-bar.sh <n>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/key-cap-bar-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
ONLY="${1:-}"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/key-cap-bar-checks.sh
. "$CHECKS"

fail() { echo "FAIL: $*" >&2; exit 1; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/key-cap-bar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# $1 dir, then one "budget:count:purged" triple per sample. "-" omits a field.
series() {
  local d="$1" n=0 t b c p
  shift
  mkdir -p "$d"
  for t in "$@"; do
    n=$((n + 1))
    b="${t%%:*}"; t="${t#*:}"; c="${t%%:*}"; p="${t#*:}"
    jq -n --arg b "$b" --arg c "$c" --arg p "$p" '
      def opt($k; $v): if $v == "-" then {} else {($k): ($v | tonumber)} end;
      {ok: true, status: {resident: (
        {resident_held_keys: 0, resident_dirty_keys: 0}
        + opt("resident_key_budget"; $b)
        + opt("resident_key_count"; $c)
        + opt("resident_purged_keys"; $p))}}' \
      >"$(printf '%s/sample-%03d.json' "$d" "$n")"
  done
}

# expect <case> <green|red> <grep pattern> <triples...>
expect() {
  local name="$1" verdict="$2" pat="$3" out rc
  shift 3
  series "$TMP/$name" "$@"
  key_cap_bar_from_samples "$TMP/$name" 100 "$TMP/$name.json" || true
  set +e
  out="$(key_cap_bar_eval "$TMP/$name.json" 2>&1)"
  rc=$?
  set -e
  if [ "$verdict" = green ]; then
    [ "$rc" -eq 0 ] || fail "case $name: must be GREEN; out=$out"
  else
    [ "$rc" -ne 0 ] || fail "case $name: must be RED; out=$out"
  fi
  printf '%s\n' "$out" | grep -q -- "$pat" || fail "case $name: output lacks '$pat'; out=$out"
}

# 1. The cap held and the purge ran.
want 1 && expect 1 green 'key-cap bar GREEN: cap=100 samples=3 max_count=100 purged_keys=9043' \
  100:0:0 100:100:812 100:100:9043
# 2. The override did not take effect: the node still runs on the default cap.
want 2 && expect 2 red 'is not the requested cap 100' \
  10000:4000:0 10000:10000:9043 10000:10000:9100
# 3. The count went above the budget.
want 3 && expect 3 red 'went above resident_key_budget' \
  100:90:0 100:140:20 100:100:60
# 4. The purge never ran.
want 4 && expect 4 red 'resident_purged_keys stayed 0' \
  100:10:0 100:40:0 100:80:0
# 5. A sample lacks a gauge (a binary without the logical resident set).
want 5 && expect 5 red 'absent fields fail the bar' \
  100:50:10 -:-:- 100:100:90
# 6. One sample is not a proof.
want 6 && expect 6 red 'need at least 2' 100:100:90
# 7. An absent proof file is RED.
if want 7; then
  set +e
  out="$(key_cap_bar_eval "$TMP/does-not-exist.json" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "case 7: an absent proof must be RED; out=$out"
fi
# 8. The gauge wire form {value: n} reads the same as a plain integer.
if want 8; then
  mkdir -p "$TMP/8"
  for n in 1 2; do
    jq -n '{status: {resident: {resident_key_budget: {value: 100},
      resident_key_count: {value: 100}, resident_purged_keys: {value: 7}}}}' \
      >"$(printf '%s/sample-%03d.json' "$TMP/8" "$n")"
  done
  key_cap_bar_from_samples "$TMP/8" 100 "$TMP/8.json"
  key_cap_bar_eval "$TMP/8.json" | grep -q 'GREEN' || fail "case 8: gauge wire form must parse"
fi

# --- driver wiring -----------------------------------------------------------
if [ -z "$ONLY" ]; then
  grep -q '\. "$_SCRIPT_DIR/key-cap-bar-checks.sh"' "$DRIVER" || fail "driver must source the key-cap bar"
  grep -q 'probe_key_cap_bar "$CANDIDATE_BIN"' "$DRIVER" || fail "driver must run the key-cap probe"
  grep -q 'key_cap_bar_eval "$KC_PROOF"' "$DRIVER" || fail "driver must score the key-cap proof"
  grep -q '"$KEY_CAP_BAR_ENV=$KEY_CAP_BAR_CAP"' "$DRIVER" || fail "driver must boot the key-cap node with the low cap"
fi

echo "ok: key-cap bar fixture"
