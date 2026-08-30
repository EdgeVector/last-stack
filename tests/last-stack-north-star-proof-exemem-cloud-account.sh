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


# --- 6. committed live evidence file PASSes in live mode -------------------
# The card END STATE needs a real PASS, not PASS-OFFLINE. The committed file
# holds only the redacted fields the validator reads, so this check runs on
# any machine, with or without a connected identity.
live_evidence="$ROOT/harness/north-star/exemem-cloud-account/evidence/live-evidence.json"
test -f "$live_evidence" || fail "committed live evidence file is missing"

EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE="$live_evidence" \
NORTH_STAR_PROOF_DIR="$WORK/live-reports" \
  "$RUNNER" --live north-star-exemem-cloud-account >"$WORK/live.out"

live_report="$WORK/live-reports/north-star-exemem-cloud-account.md"
test "$(sed -n '1p' "$live_report")" = "PASS" \
  || fail "live evidence first line was $(sed -n '1p' "$live_report")"
grep -q "existing paid account" "$live_report" \
  || fail "live report missing paid-account note"

# The committed artifact must stay free of secret-shaped text. Key PATHS are
# allowed (they name the surface that was inspected); values are not.
grep -q '"exemem_pii_leak_count": 0' "$live_evidence" \
  || fail "live evidence does not assert zero PII leaks"
grep -q 'http' "$live_evidence" && fail "live evidence contains a URL"
grep -q '@' "$live_evidence" && fail "live evidence contains an address-shaped value"
# An opaque credential is a long unbroken run of base64/hex characters. The
# checked_fields entries are dotted key paths, so they never match this.
grep -qE '"[A-Za-z0-9+/=]{24,}"' "$live_evidence" \
  && fail "live evidence contains a long opaque value (possible token)"

# --- 7. nested credentials are redacted out of the drive report ------------
# The account endpoint legitimately returns a short-lived bearer token to the
# calling device. The proof report is a durable file, so that value must never
# reach it. Redaction used to inspect only top-level keys, so account.auth.token
# was written verbatim.
stub_bin="$WORK/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/lastdb" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cloud status --help")
    echo "Print subscription / plan / quota status for the connected account."
    exit 0 ;;
  "cloud account --help")
    echo "  --json     Print JSON payload instead of opening the account URL"
    echo "  --no-open  Do not open a browser"
    exit 0 ;;
  "cloud upgrade --help")
    echo "Open Stripe Checkout to upgrade an already-connected account to paid"
    exit 0 ;;
  "cloud status")
    echo "plan:            paid"
    echo "access_allowed:  true"
    echo "storage:         quota_bytes=1099511627776"
    exit 0 ;;
  "cloud account --json --no-open")
    cat <<'JSON'
{
  "ok": true,
  "url": "https://exemem.invalid/account?t=STUBURLSECRETVALUE",
  "account": {
    "auth": {
      "token": "STUBBEARERSECRETVALUE",
      "token_type": "Bearer",
      "expires_in_seconds": 600
    },
    "status": {
      "access_allowed": true,
      "plan": "paid",
      "storage": { "quota_bytes": 1099511627776 }
    },
    "user_hash": "deadbeef"
  }
}
JSON
    exit 0 ;;
esac
echo "unexpected stub args: $*" >&2
exit 3
STUB
chmod +x "$stub_bin/lastdb"

stub_home="$WORK/stub-home"
mkdir -p "$stub_home"
PATH="$stub_bin:$PATH" \
EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME="$stub_home" \
NORTH_STAR_PROOF_DIR="$WORK/redact-reports" \
  "$RUNNER" --offline north-star-exemem-cloud-account >"$WORK/redact.out" 2>&1 \
  || fail "stub drive failed: $(cat "$WORK/redact.out")"

redact_report="$WORK/redact-reports/north-star-exemem-cloud-account.md"
test "$(sed -n '1p' "$redact_report")" = "PASS-OFFLINE" \
  || fail "stub drive report was $(sed -n '1p' "$redact_report")"
grep -q 'STUBBEARERSECRETVALUE' "$redact_report" \
  && fail "bearer token leaked into the proof report"
grep -q 'STUBURLSECRETVALUE' "$redact_report" \
  && fail "account URL query secret leaked into the proof report"
grep -q '<redacted-secret>' "$redact_report" \
  || fail "stub drive report shows no redaction marker"
grep -q '"token_type": "Bearer"' "$redact_report" \
  || fail "token_type label should survive redaction"

echo "PASS last-stack-north-star-proof-exemem-cloud-account"
