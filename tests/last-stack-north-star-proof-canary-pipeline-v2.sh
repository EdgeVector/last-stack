#!/usr/bin/env bash
# The canary v2 North Star proof must fail closed on incomplete evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HARNESS="$ROOT/harness/north-star/lastdb-canary-pipeline-v2/run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/canary-v2-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-canary-pipeline-v2: $*" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/reports"
stub="$WORK/bin/canary-pipeline"
fixture="$WORK/proof.out"

# The stub expands these values when it runs.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'cat "${CANARY_PROOF_FIXTURE:?}"' 'exit "${CANARY_PROOF_RC:-0}"' >"$stub"
chmod +x "$stub"

run_harness() {
  local mode="$1"
  NORTH_STAR_PROOF_MODE="$mode" \
    NORTH_STAR_PROOF_DIR="$WORK/reports" \
    LAST_STACK_CANARY_PIPELINE="$stub" \
    CANARY_PROOF_FIXTURE="$fixture" \
    bash "$HARNESS"
}

report="$WORK/reports/north-star-lastdb-canary-pipeline-v2.md"

# The old synthetic output must never become a PASS in either mode.
printf '%s\n' 'CANARY_PIPELINE_PROOF result=ok dry_run=1 no_primary_mutation=1 stable_mutation=false' >"$fixture"
if run_harness live >"$WORK/partial.out" 2>&1; then
  fail "partial synthetic output passed live proof"
fi
[ "$(sed -n '1p' "$report")" = FAIL ] || fail "partial proof did not leave a FAIL report"

write_complete_fixture() {
  cat >"$fixture" <<'EOF'
BOOT_LEDGER result=ok source_oid=211325fc22587c7ea0414c749ed9fd7e291677d8 installed_oid=211325fc22587c7ea0414c749ed9fd7e291677d8
OBSERVATIONS result=ok
VERDICT result=ok sep-0830=window-open sep-0831=red:restart[guard-memory] sep-0901=red:status_latency
RECONCILER result=ok
HEAL_QUEUE result=ok
CHANNELS result=ok live_build=0.23.3-1435-g211325fc2 stable_build=0.23.3-1427-g38d039aee
LOOM result=ok graph_version=lastdb-canary-release-v2 graph_hash=0123456789abcdef0123456789abcdef
DRY_RUN result=ok no_primary_mutation=1 stable_mutation=false
TEST_SUITE result=ok
EOF
}

write_complete_fixture
run_harness offline >"$WORK/offline.out"
[ "$(sed -n '1p' "$report")" = PASS-OFFLINE ] || fail "complete offline proof did not return PASS-OFFLINE"

run_harness live >"$WORK/live.out"
[ "$(sed -n '1p' "$report")" = PASS ] || fail "complete live proof did not return PASS"

# Every named evidence surface is mandatory.
write_complete_fixture
grep -v '^HEAL_QUEUE ' "$fixture" >"$WORK/missing.out"
mv "$WORK/missing.out" "$fixture"
if run_harness offline >"$WORK/missing-run.out" 2>&1; then
  fail "proof passed without HEAL_QUEUE evidence"
fi
[ "$(sed -n '1p' "$report")" = FAIL ] || fail "missing evidence did not replace the prior PASS with FAIL"

# Live identifiers must describe real artifacts, not fixture placeholders.
write_complete_fixture
sed 's/source_oid=211325fc22587c7ea0414c749ed9fd7e291677d8/source_oid=dryrun-source/' "$fixture" >"$WORK/placeholder.out"
mv "$WORK/placeholder.out" "$fixture"
if run_harness live >"$WORK/placeholder-run.out" 2>&1; then
  fail "live proof passed with a placeholder source OID"
fi
[ "$(sed -n '1p' "$report")" = FAIL ] || fail "placeholder evidence did not leave a FAIL report"

echo "PASS last-stack-north-star-proof-canary-pipeline-v2"
