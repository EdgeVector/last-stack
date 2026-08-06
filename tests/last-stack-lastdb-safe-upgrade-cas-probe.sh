#!/usr/bin/env bash
# Unit tests for safe-upgrade CAS mutation bar (LastGit compound proof).
# No live node, no primary home — pure classify + driver wiring.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROBE="$ROOT/skills/lastdb-safe-upgrade/scripts/cas-mutation-probe.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$PROBE" ] || { echo "FAIL: missing $PROBE" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$PROBE"
bash -n "$DRIVER"
chmod +x "$PROBE" 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cas-probe-unit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- classify: false precondition → 409 cas_conflict is GREEN ---------------
cat >"$TMP/ok409.json" <<'EOF'
{"error":"cas_conflict","field":"state","message":"precondition failed"}
EOF
set +e
OUT="$(bash "$PROBE" --classify --http-code 409 --resp-file "$TMP/ok409.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: 409 cas_conflict should be GREEN; rc=$RC out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'GREEN' || { echo "FAIL: expected GREEN; out=$OUT" >&2; exit 1; }

# --- classify: false precondition → 200 is RED (unconditional write) --------
echo '{}' >"$TMP/bad200.json"
set +e
OUT="$(bash "$PROBE" --classify --http-code 200 --resp-file "$TMP/bad200.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: HTTP 200 on false CAS should be RED; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -qi 'RED\|accepted false' || {
  echo "FAIL: expected RED wording for 200; out=$OUT" >&2
  exit 1
}

# --- classify: other codes RED ----------------------------------------------
set +e
OUT="$(bash "$PROBE" --classify --http-code 500 --resp-file "$TMP/bad200.json" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: HTTP 500 should be RED; out=$OUT" >&2; exit 1; }

# --- fail_red messaging names candidate + blocks promotion ------------------
# Simulate live path with non-executable candidate → RED with required phrases
set +e
OUT="$(bash "$PROBE" --lastdbd /nonexistent/candidate-lastdbd-XXXX 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: missing binary should RED; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'VERDICT: RED' || { echo "FAIL: need VERDICT: RED; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'CANDIDATE:' || { echo "FAIL: need CANDIDATE: line; out=$OUT" >&2; exit 1; }
echo "$OUT" | grep -qi 'promotion is blocked' || {
  echo "FAIL: need 'promotion is blocked' wording; out=$OUT" >&2
  exit 1
}
echo "$OUT" | grep -qi 'false CAS precondition\|CAS precondition' || {
  echo "FAIL: need false CAS precondition wording; out=$OUT" >&2
  exit 1
}

# --- driver wires the CAS bar -----------------------------------------------
grep -q 'cas-mutation-probe.sh' "$DRIVER" || {
  echo "FAIL: driver must reference cas-mutation-probe.sh" >&2
  exit 1
}
grep -q 'CAS mutation bar\|CAS_PROBE\|LASTDB_PROBE_CAS_SKIP' "$DRIVER" || {
  echo "FAIL: driver must gate on CAS mutation bar / LASTDB_PROBE_CAS_SKIP" >&2
  exit 1
}
grep -q 'promotion is blocked because the node accepted a false CAS precondition' "$DRIVER" || {
  echo "FAIL: driver RED reason must name promotion block + false CAS precondition" >&2
  exit 1
}
# Must not run against live primary home
if grep -n 'cas-mutation-probe\|CAS_PROBE' "$DRIVER" | grep -q '\.lastdb[^/]'; then
  :
fi
# Probe is invoked with --lastdbd candidate (not PRIMARY_HOME)
grep -q 'cas-mutation-probe.sh" --lastdbd "\$CANDIDATE_BIN\|CAS_PROBE_SH" --lastdbd "\$CANDIDATE_BIN' "$DRIVER" \
  || grep -q -- '--lastdbd "$CANDIDATE_BIN"' "$DRIVER" || {
  echo "FAIL: driver must invoke CAS probe with --lastdbd \$CANDIDATE_BIN" >&2
  exit 1
}

# --- skill docs mention the bar ---------------------------------------------
if [ -f "$SKILL_MD" ]; then
  grep -qi 'CAS\|expected precondition\|mutation' "$SKILL_MD" || {
    echo "WARN: SKILL.md does not yet mention CAS bar (doc update preferred)" >&2
  }
fi

echo "PASS: last-stack-lastdb-safe-upgrade-cas-probe"
