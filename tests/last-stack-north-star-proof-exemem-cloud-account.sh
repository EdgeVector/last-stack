#!/usr/bin/env bash
# Focused North Star proof for north-star-exemem-cloud-account.
# Pins: slug discovery, fixture contract (including existing-paid, no fresh
# payment), PII reject, CLI drive against a throwaway unconnected home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/exemem-cloud-account-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-exemem-cloud-account: $*" >&2
  exit 1
}

"$RUNNER" --list | grep -qx 'north-star-exemem-cloud-account' \
  || fail "--list missing north-star-exemem-cloud-account"

# --- 1. legacy 50->100 fixture still PASSes --------------------------------
legacy="$WORK/legacy-evidence.json"
cat >"$legacy" <<'JSON'
{
  "checkout": {
    "account_landing": true
  },
  "plan": {
    "before_storage_gb": 50,
    "after_storage_gb": 100,
    "displayed_storage_gb": 100
  },
  "upgrade": {
    "payment_confirmed": true
  },
  "privacy": {
    "exemem_pii_leak_count": 0,
    "checked_fields": ["accounts", "profiles", "billing_shadow"]
  }
}
JSON

EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE="$legacy" \
NORTH_STAR_PROOF_DIR="$WORK/legacy-reports" \
  "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/legacy.out"

legacy_report="$WORK/legacy-reports/north-star-exemem-cloud-account.md"
test "$(sed -n '1p' "$legacy_report")" = "PASS-OFFLINE" \
  || fail "legacy fixture first line was $(sed -n '1p' "$legacy_report")"
grep -q "50 GB -> 100 GB" "$legacy_report" || fail "legacy report missing 50->100 note"
grep -q "zero persisted PII" "$legacy_report" || fail "legacy report missing PII note"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$WORK/legacy.out" || fail "legacy stdout missing PROOF_VERDICT"

# --- 2. decision-2026-08-17 existing paid account, no 50->100 purchase ------
paid="$WORK/existing-paid.json"
cat >"$paid" <<'JSON'
{
  "checkout": {
    "account_url_present": true
  },
  "upgrade": {
    "existing_paid_account": true,
    "path_reachable": true
  },
  "privacy": {
    "exemem_pii_leak_count": 0,
    "checked_fields": ["accounts", "profiles"]
  }
}
JSON

EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE="$paid" \
NORTH_STAR_PROOF_DIR="$WORK/paid-reports" \
  "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/paid.out"

paid_report="$WORK/paid-reports/north-star-exemem-cloud-account.md"
test "$(sed -n '1p' "$paid_report")" = "PASS-OFFLINE" \
  || fail "existing-paid fixture first line was $(sed -n '1p' "$paid_report")"
grep -q "existing paid account" "$paid_report" || fail "existing-paid report missing paid-account note"
grep -q "no fresh payment" "$paid_report" || fail "existing-paid report missing no-fresh-payment note"

# --- 3. PII leak still FAILs ------------------------------------------------
bad="$WORK/bad-evidence.json"
cat >"$bad" <<'JSON'
{
  "checkout": {
    "account_landing": true
  },
  "upgrade": {
    "existing_paid_account": true
  },
  "privacy": {
    "exemem_pii_leak_count": 1,
    "checked_fields": ["accounts"]
  }
}
JSON

if EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE="$bad" \
  NORTH_STAR_PROOF_DIR="$WORK/bad-reports" \
  "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/bad.out" 2>&1; then
  fail "PII-leak evidence unexpectedly passed"
fi
test "$(sed -n '1p' "$WORK/bad-reports/north-star-exemem-cloud-account.md")" = "FAIL" \
  || fail "PII-leak report was not FAIL"

# --- 4. missing evidence/home FAILs with drive instructions -----------------
if NORTH_STAR_PROOF_DIR="$WORK/missing-reports" \
  "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/missing.out" 2>&1; then
  fail "missing evidence unexpectedly passed"
fi
missing_report="$WORK/missing-reports/north-star-exemem-cloud-account.md"
test "$(sed -n '1p' "$missing_report")" = "FAIL" || fail "missing-evidence report was not FAIL"
grep -q "EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME" "$missing_report" \
  || fail "missing-evidence report does not name the throwaway-home drive"

# --- 5. CLI drive against an unconnected throwaway home (never primary) -----
if command -v lastdb >/dev/null 2>&1; then
  throwaway="$(mktemp -d "${TMPDIR:-/tmp}/exemem-cloud-account-home.XXXXXX")"
  if EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME="$throwaway" \
    NORTH_STAR_PROOF_DIR="$WORK/drive-reports" \
    "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/drive.out" 2>&1; then
    fail "unconnected throwaway home unexpectedly passed"
  fi
  drive_report="$WORK/drive-reports/north-star-exemem-cloud-account.md"
  test "$(sed -n '1p' "$drive_report")" = "FAIL" || fail "drive report was not FAIL"
  grep -q "cloud_sync.json" "$drive_report" \
    || fail "drive report does not mention missing cloud_sync.json"
  grep -q "never complete checkout" "$drive_report" \
    || fail "drive report missing no-payment note"
  rm -rf "$throwaway"
fi

echo "PASS last-stack-north-star-proof-exemem-cloud-account"
