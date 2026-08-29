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

# The default evidence path must not be the report path. Every earlier case in
# this file passed IO_FREE_COMMIT_PROOF_EVIDENCE_FILE explicitly, so none of them
# ever ran the configuration production actually uses. The default used to
# collapse input and output onto one file: run 1 read Fold's evidence, passed,
# and overwrote it with its own summary; run 2 parsed that summary, found no
# measured lines, and failed. Assert the verdict is stable across repeated runs.
write_default_evidence() {
  {
    echo PASS-OFFLINE
    echo "- Fixture: an isolated filesystem copy of /fixture; cloud sync disabled"
    echo "- Warm apply-gate p99: 80 microseconds; bar is less than 5000"
    echo "- Reverse-index false-zero atoms: 0"
    echo "- Purge schema-barrier acquisitions: 0"
  } >"$1"
}

DEFAULT_REPORTS="$TMP/default-reports"
mkdir -p "$DEFAULT_REPORTS"
write_default_evidence "$DEFAULT_REPORTS/$SLUG.fold-evidence.md"

for run in 1 2 3; do
  NORTH_STAR_PROOF_DIR="$DEFAULT_REPORTS" "$RUNNER" --offline "$SLUG" >/dev/null
  if [ "$(head -1 "$DEFAULT_REPORTS/$SLUG.md")" != PASS-OFFLINE ]; then
    echo "FAIL: default-path run $run did not report PASS-OFFLINE" >&2
    exit 1
  fi
done

# Fold's evidence must survive every run untouched.
if ! grep -q '^- Warm apply-gate p99: 80 microseconds' \
  "$DEFAULT_REPORTS/$SLUG.fold-evidence.md"; then
  echo "FAIL: the harness overwrote the evidence it reads" >&2
  exit 1
fi

# Pointing the evidence override at the report path is the defect itself, so it
# must fail loudly rather than self-certify.
if NORTH_STAR_PROOF_DIR="$DEFAULT_REPORTS" \
  IO_FREE_COMMIT_PROOF_EVIDENCE_FILE="$DEFAULT_REPORTS/$SLUG.md" \
    "$RUNNER" --offline "$SLUG" >/dev/null 2>&1; then
  echo "FAIL: evidence pointed at the harness's own report was accepted" >&2
  exit 1
fi

echo "PASS last-stack-north-star-proof-io-free"
