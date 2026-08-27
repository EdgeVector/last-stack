#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
SLUG=north-star-lastdb-io-free-commit-and-barrierless-purge
TMP="$(mktemp -d "${TMPDIR:-/tmp}/io-free-proof-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

write_evidence() {
  local verdict="$1" p99="$2" false_zero="$3" barriers="$4"
  {
    echo "$verdict"
    echo "- Fixture: an isolated filesystem copy of /fixture; cloud sync disabled"
    echo "- Warm apply-gate p99: $p99 microseconds; bar is less than 5000"
    echo "- Reverse-index false-zero atoms: $false_zero"
    echo "- Purge schema-barrier acquisitions: $barriers"
  } >"$TMP/evidence.md"
}

write_evidence PASS-OFFLINE 499 0 0
NORTH_STAR_PROOF_DIR="$TMP/reports" \
IO_FREE_COMMIT_PROOF_EVIDENCE_FILE="$TMP/evidence.md" \
  "$RUNNER" --offline "$SLUG" >/dev/null
[ "$(head -1 "$TMP/reports/$SLUG.md")" = PASS-OFFLINE ]

write_evidence PASS-OFFLINE 5000 0 0
if NORTH_STAR_PROOF_DIR="$TMP/reports" \
  IO_FREE_COMMIT_PROOF_EVIDENCE_FILE="$TMP/evidence.md" \
    "$RUNNER" --offline "$SLUG" >/dev/null 2>&1; then
  echo "FAIL: p99 at the 5000-microsecond bar passed" >&2
  exit 1
fi
[ "$(head -1 "$TMP/reports/$SLUG.md")" = FAIL ]

write_evidence PASS-OFFLINE 499 0 0
if NORTH_STAR_PROOF_DIR="$TMP/reports" \
  IO_FREE_COMMIT_PROOF_EVIDENCE_FILE="$TMP/evidence.md" \
    "$RUNNER" --live "$SLUG" >/dev/null 2>&1; then
  echo "FAIL: live mode accepted PASS-OFFLINE" >&2
  exit 1
fi

write_evidence PASS 499 0 0
NORTH_STAR_PROOF_DIR="$TMP/reports" \
IO_FREE_COMMIT_PROOF_EVIDENCE_FILE="$TMP/evidence.md" \
  "$RUNNER" --live "$SLUG" >/dev/null
[ "$(head -1 "$TMP/reports/$SLUG.md")" = PASS ]

echo "PASS last-stack-north-star-proof-io-free"
