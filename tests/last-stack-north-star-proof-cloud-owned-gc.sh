#!/usr/bin/env bash
# The cloud-owned GC North Star has a registered, fail-closed terminal proof.
#
# Guards the defect that filed card
# lastdb-cloud-gc-required-proof-registration-20260912: with no harness folder
# the milestone driver read the North Star as proof_status=not_required. Every
# case runs on temporary directories with a fake Fold tree and a fake verifier;
# no primary home, socket or cloud account is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
SLUG=north-star-lastdb-cloud-owned-gc
FLAG=--require-full-release-proof
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cloud-owned-gc-proof-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "last-stack-north-star-proof-cloud-owned-gc: $*" >&2
  exit 1
}

# --- 1. the supported proof list includes the exact slug --------------------
bash "$RUNNER" --list | grep -qx "$SLUG" || fail "--list is missing $SLUG"

GOOD_OID=0123456789abcdef0123456789abcdef01234567
GOOD_SHA=$(printf 'a%.0s' $(seq 1 64))

# write_fold <dir> installs a fake Fold tree whose verifier is shaped by env:
#   FAKE_RC            exit status (default 0)
#   FAKE_VERDICT       evidence line 1 (default PASS)
#   FAKE_SCOPE         Proof scope (default full-release)
#   FAKE_CLASSES       Payload classes complete (default all five)
#   FAKE_NONCE_MODE    echo | stale   (default echo)
#   FAKE_RESTORE       Fresh cloud restore value (default PASS)
#   FAKE_SKIP_EVIDENCE 1 = write nothing
# The verifier refuses any argument other than the exact full-proof flag, so a
# harness that drops or renames the flag cannot pass these cases.
write_fold() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat >"$dir/scripts/prove-cloud-owned-gc" <<'V'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = --require-full-release-proof ] || { echo "wrong args: $*" >&2; exit 3; }
[ -n "${CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE:-}" ] || { echo "no evidence path" >&2; exit 3; }
[ -n "${CLOUD_OWNED_GC_PROOF_NONCE:-}" ] || { echo "no nonce" >&2; exit 3; }
[ -n "${NORTH_STAR_PROOF_MODE:-}" ] || { echo "no mode" >&2; exit 3; }
nonce="$CLOUD_OWNED_GC_PROOF_NONCE"
[ "${FAKE_NONCE_MODE:-echo}" = echo ] || nonce="stale-nonce"
if [ "${FAKE_SKIP_EVIDENCE:-0}" != 1 ]; then
  {
    echo "${FAKE_VERDICT:-PASS}"
    echo "- Harness nonce: $nonce"
    echo "- Proof scope: ${FAKE_SCOPE:-full-release}"
    echo "- Source oid: ${FAKE_OID:-0123456789abcdef0123456789abcdef01234567}"
    echo "- Daemon sha256: ${FAKE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    echo "- Fixture: isolated copy of a real-data home; cloud sync disabled; never the primary"
    echo "- Payload classes complete: ${FAKE_CLASSES:-backup-chunks manifests mutation-logs owned-file-versions declared-caches}"
    echo "- Physical absence before boot: PASS"
    echo "- Retained controls: PASS"
    echo "- Cold boots: 2"
    echo "- Fresh cloud restore: ${FAKE_RESTORE:-PASS}"
    echo "- Concurrent publication: PASS"
    echo "- Source device disconnected before completion: PASS"
    echo "- Exact object bytes reconciled: PASS"
  } >"$CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE"
fi
echo "PASS full release proof"
exit "${FAKE_RC:-0}"
V
  chmod +x "$dir/scripts/prove-cloud-owned-gc"
}

# run_case <name> <mode> <expected-first-line> <expected-rc:0|1> [<report-regex>]
run_case() {
  local name="$1" mode="$2" want="$3" want_rc="$4" pattern="${5:-}"
  local reports="$TMP/reports-$name"
  rm -rf "$reports"
  mkdir -p "$reports"
  set +e
  NORTH_STAR_PROOF_DIR="$reports" bash "$RUNNER" "--$mode" "$SLUG" >"$TMP/$name.out" 2>&1
  local rc=$?
  set -e
  local report="$reports/$SLUG.md"
  [ -f "$report" ] || fail "$name: no report written"
  local first
  first="$(sed -n '1p' "$report")"
  [ "$first" = "$want" ] || fail "$name: expected $want, got $first ($(grep -c FAIL "$report") FAIL notes)"
  if [ "$want_rc" -eq 0 ]; then
    [ "$rc" -eq 0 ] || fail "$name: runner exited $rc, expected 0"
  else
    [ "$rc" -ne 0 ] || fail "$name: runner exited 0, expected nonzero"
  fi
  if [ -n "$pattern" ]; then
    grep -qE "$pattern" "$report" || fail "$name: report lacks /$pattern/"
  fi
}

FOLD="$TMP/fold"
write_fold "$FOLD"
export CLOUD_OWNED_GC_FOLD_SOURCE="$FOLD"

# --- 2. absent verifier exits nonzero with a named reason -------------------
mkdir -p "$TMP/fold-empty"
CLOUD_OWNED_GC_FOLD_SOURCE="$TMP/fold-empty" \
  run_case absent offline FAIL 1 'missing-proof: Fold verifier scripts/prove-cloud-owned-gc is absent'

# --- 3. the workspace portal is never a source tree -------------------------
mkdir -p "$TMP/portal/.portal"
CLOUD_OWNED_GC_FOLD_SOURCE="$TMP/portal" \
  run_case portal offline FAIL 1 'workspace portal, which holds no checkout'

# --- 4. a failing verifier stays failed even though it prints PASS ----------
FAKE_RC=7 run_case failing-verifier offline FAIL 1 'verifier exited 7 with --require-full-release-proof'

# --- 5. private-only evidence cannot become a full release PASS -------------
FAKE_SCOPE=private-dev run_case private-only offline FAIL 1 "found 'private-dev'"

# --- 6. an incomplete payload-class set is not cloud erasure ----------------
FAKE_CLASSES="backup-chunks manifests" run_case incomplete-classes offline FAIL 1 'missing: mutation-logs owned-file-versions declared-caches'

# --- 7. a stale evidence file (wrong nonce) is not this run's proof ---------
FAKE_NONCE_MODE=stale run_case stale-nonce offline FAIL 1 'stale or foreign evidence'

# --- 8. a verifier that writes no evidence fails closed ---------------------
FAKE_SKIP_EVIDENCE=1 run_case no-evidence offline FAIL 1 'verifier wrote evidence'

# --- 9. an unbound evidence file (no source oid) is refused -----------------
FAKE_OID=unknown run_case unbound offline FAIL 1 "bound to a source oid \(found 'unknown'\)"

# --- 10. evidence bound to a different source than the resolved tree --------
CLOUD_OWNED_GC_FOLD_SOURCE_OID=ffffffffffffffffffffffffffffffffffffffff \
  run_case oid-mismatch offline FAIL 1 'matches the resolved tree'

# --- 11. one failed sub-proof fails the whole proof -------------------------
FAKE_RESTORE=FAIL run_case restore-failed offline FAIL 1 "Fresh cloud restore \(found 'FAIL'\)"

# --- 12. evidence pointed at the harness's own report is refused ------------
mkdir -p "$TMP/reports-self"
set +e
NORTH_STAR_PROOF_DIR="$TMP/reports-self" \
CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE="$TMP/reports-self/$SLUG.md" \
  bash "$RUNNER" --offline "$SLUG" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "self-report: evidence at the report path was accepted"
grep -q "own report" "$TMP/reports-self/$SLUG.md" || fail "self-report: reason not named"

# --- 13. the complete full-release proof passes, and the flag is recorded ---
run_case good-offline offline PASS-OFFLINE 0 "scripts/prove-cloud-owned-gc $FLAG"
run_case good-live live PASS 0 'bound to source oid 0123456789abcdef0123456789abcdef01234567'
grep -q "evidence carries this invocation's nonce: PASS" "$TMP/reports-good-live/$SLUG.md" \
  || fail "good-live: nonce binding not recorded"
# The matching-oid path is exercised too: same oid on both sides passes.
CLOUD_OWNED_GC_FOLD_SOURCE_OID="$GOOD_OID" run_case oid-match live PASS 0 "bound to source oid $GOOD_OID"
# Fold's evidence survives the run untouched (the harness reads, never rewrites).
grep -q "^- Daemon sha256: $GOOD_SHA" "$TMP/reports-good-live/$SLUG.fold-evidence.md" \
  || fail "good-live: the harness rewrote or dropped Fold's evidence"

echo "PASS last-stack-north-star-proof-cloud-owned-gc"
