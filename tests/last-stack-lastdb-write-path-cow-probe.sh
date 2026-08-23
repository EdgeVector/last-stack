#!/usr/bin/env bash
# Unit tests for the write-path CoW probe (Table 5). No live node, no primary
# home write. Classify incumbent RED / Table 5 GREEN; refuse live --data-dir;
# require live_lastdb_env_pairs reuse.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROBE="$ROOT/skills/lastdb-safe-upgrade/scripts/write-path-cow-probe.sh"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/write-path-cow-checks.sh"
ENVSH="$ROOT/skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$PROBE" ] || fail "missing $PROBE"
[ -f "$CHECKS" ] || fail "missing $CHECKS"
[ -f "$ENVSH" ] || fail "missing $ENVSH"
[ -f "$DRIVER" ] || fail "missing $DRIVER"
[ -x "$PROBE" ] || fail "probe not executable: $PROBE"
[ -x "$ENVSH" ] || chmod +x "$ENVSH" "$CHECKS" "$PROBE" 2>/dev/null || true

bash -n "$PROBE"
bash -n "$CHECKS"
bash -n "$ENVSH"
bash -n "$DRIVER"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/write-path-cow-checks.sh
. "$CHECKS"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh
. "$ENVSH"

type live_lastdb_env_pairs >/dev/null 2>&1 \
  || fail "live_lastdb_env_pairs must be defined (reuse, not a second env-mirror)"

grep -q 'live_lastdb_env_pairs' "$PROBE" \
  || fail "probe must call live_lastdb_env_pairs"
grep -q 'live-lastdb-env.sh' "$PROBE" \
  || fail "probe must source live-lastdb-env.sh"
grep -q 'live-lastdb-env.sh' "$DRIVER" \
  || fail "driver must source live-lastdb-env.sh (single env-mirror)"
grep -q 'live_lastdb_env_pairs' "$DRIVER" \
  || fail "driver must still call live_lastdb_env_pairs"

# --- refuse live-home --data-dir --------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/write-path-cow-unit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

set +e
OUT="$(bash "$PROBE" --refuse-data-dir "$HOME/.lastdb" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "live-home --data-dir must RED; out=$OUT"
echo "$OUT" | grep -q 'VERDICT: RED' || fail "need VERDICT: RED for live home; out=$OUT"

set +e
OUT="$(bash "$PROBE" --refuse-data-dir "$TMP" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "isolated --data-dir must GREEN; out=$OUT"

# --- classify incumbent-shaped sample RED -----------------------------------
cat >"$TMP/incumbent.json" <<'EOF'
{
  "ack_ms": 4500,
  "persist_mode": "awaited",
  "sync_capture_mode": "awaited",
  "purge_in_batch": true,
  "purge_barrier_ms": 2270,
  "p50_ms": 4500,
  "p95_ms": 8000,
  "exclusive_purge": true
}
EOF
set +e
OUT="$(bash "$PROBE" --classify --sample-file "$TMP/incumbent.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "incumbent sample must RED; out=$OUT"
echo "$OUT" | grep -q 'VERDICT: RED' || fail "need VERDICT: RED; out=$OUT"
echo "$OUT" | grep -Eq 'seconds-scale|persist|sync_capture|Purge' \
  || fail "RED reasons must name persist/T2/purge/seconds; out=$OUT"

# Same classification via sourced helper (no subprocess).
set +e
OUT="$(write_path_classify_sample 4500 awaited awaited 1 2270 4500 8000 1 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "helper incumbent sample must RED; out=$OUT"

# --- classify Table 5 sample GREEN ------------------------------------------
cat >"$TMP/table5.json" <<'EOF'
{
  "ack_ms": 40,
  "persist_mode": "spawn-only",
  "sync_capture_mode": "encode-only",
  "purge_in_batch": false,
  "purge_barrier_ms": 0,
  "p50_ms": 40,
  "p95_ms": 80,
  "exclusive_purge": false
}
EOF
set +e
OUT="$(bash "$PROBE" --classify --sample-file "$TMP/table5.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "Table 5 sample must GREEN; out=$OUT"
echo "$OUT" | grep -q 'VERDICT: GREEN' || fail "need VERDICT: GREEN; out=$OUT"
echo "$OUT" | grep -q 'spawn-only' || fail "GREEN should name spawn-only; out=$OUT"
echo "$OUT" | grep -q 'encode-only' || fail "GREEN should name encode-only; out=$OUT"

set +e
OUT="$(write_path_classify_sample 40 spawn-only encode-only 0 0 40 80 0 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "helper Table 5 sample must GREEN; out=$OUT"

# Correct-but-slow (persist spawn-only but p50 still seconds) is RED.
set +e
OUT="$(write_path_classify_sample 1500 spawn-only encode-only 0 0 1500 2000 0 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "correct-but-slow must RED; out=$OUT"

# Probe clones into TMPDIR, never $HOME.
grep -q 'cp -cR' "$PROBE" || fail "probe must clone with cp -cR"
grep -q 'TMPDIR' "$PROBE" || fail "probe must clone under TMPDIR"
grep -q 'cloud_sync.json' "$PROBE" || fail "probe must strip production cloud_sync.json"
if grep -E -- '--data-dir[~ ]*/\.lastdb|"--data-dir ~/.lastdb"' "$PROBE" | grep -vq 'refuse\|RED\|never\|live-home'; then
  fail "probe must not pass --data-dir ~/.lastdb"
fi

# Skill docs mention the write-path probe.
if [ -f "$SKILL_MD" ]; then
  grep -qi 'write-path\|Table 5\|T0' "$SKILL_MD" \
    || echo "WARN: SKILL.md does not yet mention write-path CoW probe" >&2
fi

echo "OK: write-path CoW probe (packaged, live_lastdb_env_pairs reused, live-home refused, incumbent RED, Table 5 GREEN)"
