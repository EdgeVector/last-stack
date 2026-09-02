#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/no-scan-tracker-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proofs"

cat >"$WORK/tracker.json" <<'EOF'
{
  "slug": "lastdb-scan-deprecation-tracker",
  "kind": "tracker",
  "column": "done",
  "body": "## COMPLETION RULE\nAll named kill-scan cards must be complete.\n\nPROOF: keyed completion checkpoints verified."
}
EOF

run_proof() {
  NORTH_STAR_PROOF_MODE=live \
  NORTH_STAR_PROOF_DIR="$WORK/proofs" \
  LASTDB_NO_SCAN_TRACKER_FILE="$1" \
    "$RUNNER" --live north-star-lastdb-no-scan-access
}

run_proof "$WORK/tracker.json" >/dev/null
test "$(sed -n '1p' "$WORK/proofs/north-star-lastdb-no-scan-access.md")" = PASS

if run_proof "$WORK/absent.json" >/dev/null 2>&1; then
  echo "missing tracker unexpectedly passed" >&2
  exit 1
fi
test "$(sed -n '1p' "$WORK/proofs/north-star-lastdb-no-scan-access.md")" = FAIL

sed 's/"done"/"todo"/' "$WORK/tracker.json" >"$WORK/open-tracker.json"
if run_proof "$WORK/open-tracker.json" >/dev/null 2>&1; then
  echo "open tracker unexpectedly passed" >&2
  exit 1
fi

if NORTH_STAR_PROOF_MODE=offline \
  NORTH_STAR_PROOF_DIR="$WORK/proofs" \
  LASTDB_NO_SCAN_TRACKER_FILE="$WORK/tracker.json" \
    "$RUNNER" --offline north-star-lastdb-no-scan-access >/dev/null 2>&1; then
  echo "offline mode unexpectedly satisfied the live tracker gate" >&2
  exit 1
fi

echo "ok: LastDB no-scan tracker gate fails closed"
