#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-proof"
export NORTH_STAR_PROOF_DIR="$(mktemp -d)"
trap 'rm -rf "$NORTH_STAR_PROOF_DIR"' EXIT

# list includes the slug
"$BIN" --list | grep -qx 'north-star-lastdb-cloud-backup-restore-proof'

# offline run against live brain evidence when available
set +e
out="$("$BIN" --offline north-star-lastdb-cloud-backup-restore-proof 2>&1)"
rc=$?
set -e
report="$NORTH_STAR_PROOF_DIR/north-star-lastdb-cloud-backup-restore-proof.md"
test -f "$report"
first="$(head -n 1 "$report")"
if command -v brain >/dev/null 2>&1 && brain get north-star-lastdb-cloud-backup-restore-proof --type project >/dev/null 2>&1; then
  test "$rc" -eq 0
  case "$first" in
    PASS|PASS-OFFLINE) ;;
    *) echo "expected PASS* got $first"; exit 1 ;;
  esac
  grep -qiE 'restore|tamper|validated' "$report"
else
  # without brain, harness may FAIL — still must write a report
  test -n "$first"
fi
echo "PASS last-stack-north-star-proof-cloud-backup"
