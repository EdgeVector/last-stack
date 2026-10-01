#!/usr/bin/env bash
# Fixture tests for the safe-upgrade footprint bar.
# Sample status JSON only. This test does not start lastdbd and does not
# read the primary home.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/footprint-bar-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
ENVSH="$ROOT/skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
[ -f "$ENVSH" ] || { echo "FAIL: missing $ENVSH" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
bash -n "$ENVSH"
chmod +x "$CHECKS" 2>/dev/null || true

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/footprint-bar-checks.sh
. "$CHECKS"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh
. "$ENVSH"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/footprint-bar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# 8 GiB phys, 256 MiB slack, 256 MiB freed, exact 0.25 drop (64 MiB).
# p99 is 10 GiB. Multiplier is 1.1. Both backstops stay under the line.
cat >"$TMP/pass.json" <<'EOF'
{
  "proof_kind": "upgrade-gate",
  "duration_secs": 600,
  "purge_delay_ms": 0,
  "request_end_collect": true,
  "phys_footprint": 8589934592,
  "footprint_net": 8321499136,
  "p99_phys_footprint": 10737418240,
  "multiplier": 1.1,
  "steps": [
    {
      "warm_bytes_freed": 268435456,
      "footprint_before": 8589934592,
      "footprint_after": 8522825728
    }
  ]
}
EOF

# Same sample with footprint_net removed. Must fail. Must not skip.
jq 'del(.footprint_net)' "$TMP/pass.json" >"$TMP/no-net.json"

# Slack is 512 MiB + 1 byte. Every other field still meets the bar.
jq '.footprint_net = 8053063679' "$TMP/pass.json" >"$TMP/slack.json"

# Slack exactly 512 MiB still passes.
jq '.footprint_net = 8053063680' "$TMP/pass.json" >"$TMP/slack-eq.json"

# Old status shape. No new fields. Equivalent to build be41e547e.
cat >"$TMP/old.json" <<'EOF'
{
  "status": {
    "phys_footprint_bytes": 11940000000,
    "rss_bytes": 1500000000,
    "build": {"version": "be41e547e"}
  }
}
EOF

# An unfixed stub that ignores the sample must not be what this test calls.
footprint_bar_eval_unfixed() {
  printf 'footprint bar GREEN: unfixed\n'
  return 0
}
set +e
UNFIXED_OUT="$(footprint_bar_eval_unfixed "$TMP/no-net.json" 2>&1)"
UNFIXED_RC=$?
set -e
[ "$UNFIXED_RC" -eq 0 ] || fail "unfixed stub must return 0"
echo "$UNFIXED_OUT" | grep -q ' RED:' \
  && fail "unfixed stub must not print RED — otherwise this test cannot fail on the old code"

# --- pass -------------------------------------------------------------------
set +e
OUT="$(footprint_bar_eval "$TMP/pass.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "meeting sample must pass; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'footprint bar GREEN: proof_kind=upgrade-gate duration_secs=600' \
  || fail "expected upgrade-gate receipt; out=$OUT"
echo "$OUT" | grep -q 'purge_delay_ms=0' || fail "receipt must record purge_delay_ms=0; out=$OUT"
echo "$OUT" | grep -q 'slack_bytes=268435456' || fail "expected 256 MiB slack; out=$OUT"
echo "$OUT" | grep -q 'p99_backstop=12GiB' || fail "12 GiB p99 must stay a named backstop; out=$OUT"
echo "$OUT" | grep -q 'multiplier_backstop=1.3' || fail "1.3 multiplier must stay a named backstop; out=$OUT"

# --- lacks footprint_net ----------------------------------------------------
export LASTDB_PROBE_FOOTPRINT_SKIP=1
set +e
OUT="$(footprint_bar_eval "$TMP/no-net.json" 2>&1)"
RC=$?
set -e
unset LASTDB_PROBE_FOOTPRINT_SKIP
[ "$RC" -ne 0 ] || fail "sample without footprint_net must fail; out=$OUT"
echo "$OUT" | grep -q ' RED:' || fail "missing footprint_net must print RED; out=$OUT"
echo "$OUT" | grep -q 'footprint_net' || fail "RED must name footprint_net; out=$OUT"
echo "$OUT" | grep -q 'not skipped' || fail "absent field must not skip; out=$OUT"
echo "$OUT" | grep -q 'SKIPPED' && fail "absent field must not print SKIPPED; out=$OUT"

# --- slack above 512 MiB ----------------------------------------------------
set +e
OUT="$(footprint_bar_eval "$TMP/slack.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "slack above 512 MiB must fail; out=$OUT"
echo "$OUT" | grep -q 'above 512 MiB' || fail "expected slack RED; out=$OUT"

set +e
OUT="$(footprint_bar_eval "$TMP/slack-eq.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "slack of exactly 512 MiB must pass; rc=$RC out=$OUT"

# --- be41e547e equivalent ---------------------------------------------------
set +e
OUT="$(footprint_bar_eval "$TMP/old.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "be41e547e status must fail; out=$OUT"
echo "$OUT" | grep -q 'footprint_net' || fail "be41e547e RED must name footprint_net; out=$OUT"
echo "$OUT" | grep -q 'not skipped' || fail "be41e547e must not skip; out=$OUT"

# --- soak is not the upgrade gate ------------------------------------------
jq '.duration_secs = 86400 | .proof_kind = "long-memory-candidate"' "$TMP/pass.json" >"$TMP/soak.json"
set +e
OUT="$(footprint_bar_eval "$TMP/soak.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "86400 soak must fail; out=$OUT"
echo "$OUT" | grep -q 'soak, not the upgrade gate' || fail "soak RED must name the gate; out=$OUT"

[ "$(footprint_bar_proof_kind 600)" = "upgrade-gate" ] || fail "600 must be upgrade-gate"
[ "$(footprint_bar_proof_kind 86399)" = "upgrade-gate" ] || fail "86399 must be upgrade-gate"
[ "$(footprint_bar_proof_kind 86400)" = "long-memory-candidate" ] || fail "86400 must be the soak"
[ "$(footprint_bar_proof_kind 599)" = "short" ] || fail "599 must be short"

# --- other required failures ------------------------------------------------
jq '.purge_delay_ms = 1' "$TMP/pass.json" >"$TMP/delay.json"
set +e
OUT="$(footprint_bar_eval "$TMP/delay.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "nonzero purge_delay_ms must fail; out=$OUT"

jq '.steps[0].footprint_after = 8589934591' "$TMP/pass.json" >"$TMP/ratio.json"
set +e
OUT="$(footprint_bar_eval "$TMP/ratio.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "drop under 0.25 must fail; out=$OUT"
echo "$OUT" | grep -q '0.25' || fail "ratio RED must name 0.25; out=$OUT"

jq '.p99_phys_footprint = 12884901888' "$TMP/pass.json" >"$TMP/p99.json"
set +e
OUT="$(footprint_bar_eval "$TMP/p99.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "p99 at 12 GiB must fail the backstop; out=$OUT"

jq '.multiplier = 1.3' "$TMP/pass.json" >"$TMP/mult.json"
set +e
OUT="$(footprint_bar_eval "$TMP/mult.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "multiplier 1.3 must fail the backstop; out=$OUT"

# --- stamp stays on the copy ------------------------------------------------
footprint_stamp_env_allowed ephemeral-copy 1 || fail "copy may set the stamp flag"
footprint_stamp_env_allowed primary "" || fail "unset primary stamp flag is allowed"
footprint_stamp_env_allowed primary 0 || fail "primary 0 is allowed"
if footprint_stamp_env_allowed primary 1; then
  fail "primary must not carry LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1"
fi
footprint_copy_is_not_primary /tmp/footprint-copy /tmp/footprint-primary \
  || fail "distinct copy and primary must pass"
if footprint_copy_is_not_primary /tmp/footprint-primary /tmp/footprint-primary; then
  fail "copy must not be the primary home"
fi
if footprint_copy_is_not_primary /tmp/footprint-primary/child /tmp/footprint-primary; then
  fail "copy inside the primary home must fail"
fi

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
stamp_val="$(footprint_plist_stamp_value "$plist")"
if footprint_stamp_env_allowed primary "$stamp_val"; then
  fail "plist stamp value must be rejected for the primary"
fi

# --- driver wires the bar and does not skip or restart for it --------------
grep -q 'footprint-bar-checks.sh' "$DRIVER" || fail "driver must source footprint-bar-checks.sh"
grep -q 'footprint_bar_eval' "$DRIVER" || fail "driver must call footprint_bar_eval"
grep -q 'LASTDB_PROBE_FOOTPRINT_SKIP' "$DRIVER" \
  && fail "driver must not grow a skip flag for the footprint bar"
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
grep -q 'footprint_stamp_env_allowed primary' "$DRIVER" \
  || fail "driver must reject the stamp flag on the primary"
grep -q 'footprint_copy_is_not_primary' "$DRIVER" \
  || fail "driver must refuse a copy that is the primary home"
grep -q 'upgrade-gate' "$SKILL_MD" || fail "SKILL.md must name upgrade-gate"
grep -q '86400' "$SKILL_MD" || fail "SKILL.md must say the soak is not the gate"
grep -q '512 MiB' "$SKILL_MD" || fail "SKILL.md must name the 512 MiB slack"
grep -q '0.25' "$SKILL_MD" || fail "SKILL.md must name the 0.25 drop"
grep -q '12 GiB' "$SKILL_MD" || fail "SKILL.md must keep the 12 GiB backstop"
grep -q '1.3' "$SKILL_MD" || fail "SKILL.md must keep the 1.3 backstop"
grep -q 'FOOTPRINT:' "$SKILL_MD" || fail "SKILL.md must name the receipt line"
grep -q 'FOOTPRINT:' "$DRIVER" || fail "driver must print the FOOTPRINT receipt"

echo "ok: footprint bar fixture"
