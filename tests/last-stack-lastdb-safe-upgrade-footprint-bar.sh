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

jq '.p99_phys_footprint = 9223372036854776000' "$TMP/pass.json" >"$TMP/p99-huge.json"
set +e
OUT="$(footprint_bar_eval "$TMP/p99-huge.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a p99 bash cannot compare must fail; out=$OUT"
echo "$OUT" | grep -q ' RED:' || fail "huge proof p99 must print RED; out=$OUT"

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
mkdir -p "$TMP/primary/child" "$TMP/elsewhere"
ln -s "$TMP/primary" "$TMP/primary-link"
if footprint_copy_is_not_primary "$TMP/primary/" "$TMP/primary"; then
  fail "a trailing slash must not make the primary path look distinct"
fi
if footprint_copy_is_not_primary "$TMP/primary/child" "$TMP/primary/"; then
  fail "a trailing slash on the primary must still reject a child"
fi
if footprint_copy_is_not_primary "$TMP/primary-link" "$TMP/primary"; then
  fail "a symlink to the primary home must fail"
fi
if footprint_copy_is_not_primary "$TMP/elsewhere" "$TMP/primary"; then
  :
else
  fail "a real directory outside the primary must pass"
fi
if grep -n 'footprint_copy_is_not_primary' "$DRIVER" | grep -q 'rm -rf'; then
  fail "a failed primary-path check must not sit on an rm -rf line"
fi
awk '
  /if ! footprint_copy_is_not_primary "\$c_copy"/ { c=1; n=0 }
  /if ! footprint_copy_is_not_primary "\$b_copy"/ { c=1; n=0 }
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

# --- one live status body is not the proof --------------------------------
cat >"$TMP/live-status.json" <<'EOF'
{
  "ok": true,
  "status": {
    "phys_footprint_bytes": 8589934592,
    "memory_budget": {
      "footprint_net_bytes": 8321499136,
      "warm_bytes_freed": 268435456,
      "implied_footprint_multiplier": 1.1
    }
  }
}
EOF
set +e
OUT="$(footprint_bar_eval "$TMP/live-status.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "one status body must fail even with footprint_net; out=$OUT"
echo "$OUT" | grep -q 'one status body is not a 600 second upgrade-gate proof' \
  || fail "status RED must say one body is not the proof; out=$OUT"
echo "$OUT" | grep -q 'footprint_net is present' \
  || fail "status RED must not claim footprint_net is absent; out=$OUT"
echo "$OUT" | grep -q 'lacks footprint_net' \
  && fail "a body that has footprint_net must not say it lacks it; out=$OUT"

# --- harness report ----------------------------------------------------------
cat >"$TMP/harness.json" <<'EOF'
{
  "ok": true,
  "failures": [],
  "proof_kind": "upgrade-gate",
  "duration_secs": 600,
  "p99_phys_footprint_bytes": 10737418240,
  "full_allocator_proof": false
}
EOF
set +e
OUT="$(footprint_bar_eval "$TMP/harness.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "harness report must pass; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'proof_kind=upgrade-gate duration_secs=600' \
  || fail "harness receipt must name the gate; out=$OUT"
jq '.ok = false' "$TMP/harness.json" >"$TMP/harness-fail.json"
set +e
OUT="$(footprint_bar_eval "$TMP/harness-fail.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a failed harness report must fail; out=$OUT"
jq '.p99_phys_footprint_bytes = ""' "$TMP/harness.json" >"$TMP/harness-empty-p99.json"
set +e
OUT="$(footprint_bar_eval "$TMP/harness-empty-p99.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "an empty harness p99 must fail; out=$OUT"
echo "$OUT" | grep -q ' RED:' || fail "empty harness p99 must print RED; out=$OUT"
jq '.p99_phys_footprint_bytes = "99999999999999999999"' "$TMP/harness.json" >"$TMP/harness-huge-p99.json"
set +e
OUT="$(footprint_bar_eval "$TMP/harness-huge-p99.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a harness p99 bash cannot compare must fail; out=$OUT"
echo "$OUT" | grep -q ' RED:' || fail "huge harness p99 must print RED; out=$OUT"
jq 'del(.status.memory_budget.footprint_net_bytes) | .status.memory_budget.footprint_net = 8321499136' \
  "$TMP/live-status.json" >"$TMP/live-status-net.json"
set +e
OUT="$(footprint_bar_eval "$TMP/live-status-net.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "status with footprint_net must fail; out=$OUT"
echo "$OUT" | grep -q 'footprint_net is present' \
  || fail "status RED must see footprint_net; out=$OUT"
echo "$OUT" | grep -q 'lacks footprint_net' \
  && fail "footprint_net must not be described as absent; out=$OUT"

# --- sample series, clock duration from the caller --------------------------
mkdir -p "$TMP/series"
cat >"$TMP/series/sample-001.json" <<'EOF'
{
  "ok": true,
  "status": {
    "phys_footprint_bytes": 8589934592,
    "memory_budget": {
      "footprint_net_bytes": 8321499136,
      "warm_bytes_freed": 0,
      "implied_footprint_multiplier": 1.05
    }
  }
}
EOF
cat >"$TMP/series/sample-002.json" <<'EOF'
{
  "ok": true,
  "status": {
    "phys_footprint_bytes": 8522825728,
    "memory_budget": {
      "footprint_net_bytes": 8254390272,
      "warm_bytes_freed": 268435456,
      "implied_footprint_multiplier": 1.1
    }
  }
}
EOF
footprint_bar_from_samples "$TMP/series" 600 0 "$TMP/series-proof.json" \
  || fail "two samples and a 600 second clock must build a proof"
set +e
OUT="$(footprint_bar_eval "$TMP/series-proof.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "sample series must pass; rc=$RC out=$OUT"
echo "$OUT" | grep -q 'purge_delay_ms=0' || fail "series receipt must record purge 0; out=$OUT"
echo "$OUT" | grep -q 'duration_secs=600' || fail "series duration must be the caller clock; out=$OUT"
footprint_bar_from_samples "$TMP/series" 599 0 "$TMP/series-short.json" \
  || fail "a short clock must still write a document"
set +e
OUT="$(footprint_bar_eval "$TMP/series-short.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a 599 second clock must fail the gate; out=$OUT"
mkdir -p "$TMP/one"
cp "$TMP/series/sample-001.json" "$TMP/one/sample-001.json"
if footprint_bar_from_samples "$TMP/one" 600 0 "$TMP/one-proof.json"; then
  fail "one sample must not become a proof"
fi

# --- no pressure: the governor had no cause to evict ------------------------
# Measured 2026-10-04 on fold f716d2609 (the logical resident set): peak RSS
# 420 MB, every gate passed, and the bar went RED with "no step freed warm
# bytes" because a node that stays small never evicts. governor_state=under on
# every sample, with the counter present, is the node's own statement that
# nothing needed eviction. Anything less keeps the RED.
np_series() {
  # $1 dir, $2 governor_state for sample 2 ("-" omits it), $3 "nofreed" omits the counter
  local d="$1" gov2="$2" mode="${3:-}"
  mkdir -p "$d"
  local n gov freed
  for n in 1 2 3; do
    gov="under"
    [ "$n" -eq 2 ] && gov="$gov2"
    jq -n --arg gov "$gov" --arg mode "$mode" '
      {ok: true, status: {phys_footprint_bytes: 440401920,
        memory_budget: ({footprint_net_bytes: 300000000,
          implied_footprint_multiplier: 1.05}
          + (if $mode == "nofreed" then {} else {warm_bytes_freed: 0} end)
          + (if $gov == "-" then {} else {governor_state: $gov} end))}}' \
      >"$(printf '%s/sample-%03d.json' "$d" "$n")"
  done
}
np_series "$TMP/np-under" under
footprint_bar_from_samples "$TMP/np-under" 600 0 "$TMP/np-under.json" \
  || fail "no-pressure series must build a proof"
set +e
OUT="$(footprint_bar_eval "$TMP/np-under.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "governor under on every sample must pass with no freed step; out=$OUT"
echo "$OUT" | grep -q 'drop_ratio=not-applicable governor_under_samples=3' \
  || fail "no-pressure GREEN must say the ratio was not applicable; out=$OUT"
echo "$OUT" | grep -q 'drop_ratio_ok=1' \
  && fail "no-pressure GREEN must not claim a scored ratio; out=$OUT"

np_series "$TMP/np-evicting" evicting
footprint_bar_from_samples "$TMP/np-evicting" 600 0 "$TMP/np-evicting.json"
set +e
OUT="$(footprint_bar_eval "$TMP/np-evicting.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "one evicting sample with no freed step must fail; out=$OUT"
echo "$OUT" | grep -q 'no step freed warm bytes' || fail "evicting RED must name the drop; out=$OUT"

np_series "$TMP/np-absent" -
footprint_bar_from_samples "$TMP/np-absent" 600 0 "$TMP/np-absent.json"
set +e
OUT="$(footprint_bar_eval "$TMP/np-absent.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "an absent governor_state must fail, never skip; out=$OUT"

np_series "$TMP/np-nofreed" under nofreed
footprint_bar_from_samples "$TMP/np-nofreed" 600 0 "$TMP/np-nofreed.json"
set +e
OUT="$(footprint_bar_eval "$TMP/np-nofreed.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "an absent warm_bytes_freed counter must fail even when under; out=$OUT"

# A proof that says nothing about the governor keeps the old RED.
jq '.steps = [] | del(.governor_no_pressure)' "$TMP/pass.json" >"$TMP/np-doc.json"
set +e
OUT="$(footprint_bar_eval "$TMP/np-doc.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a proof with no step and no governor evidence must fail; out=$OUT"

# --- driver scores the series, not one curl ---------------------------------
grep -q 'footprint_collect_upgrade_gate' "$DRIVER" \
  || fail "driver must collect the upgrade-gate series"
grep -q 'footprint-proof.json' "$DRIVER" || fail "driver must write a proof document"
if grep -q 'footprint-status.json' "$DRIVER"; then
  fail "driver must not keep the one-status sample file"
fi
grep -q -- '-u LASTDB_BUILD_CONFLICT_STAMP_ON_COPY' "$DRIVER" \
  || fail "probe env must clear an inherited stamp flag"
grep -q -- '-u MIMALLOC_PURGE_DELAY' "$DRIVER" \
  || fail "probe env must clear MIMALLOC_PURGE_DELAY so purge_delay_ms stays 0"
grep -q 'FOOTPRINT_BAR_UPGRADE_GATE_SECS' "$CHECKS" \
  || fail "the collector must use the 600 second gate constant"

echo "ok: footprint bar fixture"
