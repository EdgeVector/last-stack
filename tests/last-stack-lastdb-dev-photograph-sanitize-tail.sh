#!/usr/bin/env bash
# Exercise the bounded, fail-closed DEV photograph evidence sanitizer.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)"
SANITIZER="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-sanitize-tail.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$SANITIZER" ] && [ ! -L "$SANITIZER" ] \
  || fail "the DEV photograph sanitizer is absent or unsafe"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-dev-sanitize-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
COW="$TMP/cow"
RAW="$TMP/raw.log"
SAFE="$TMP/safe.log"
mkdir -p "$COW/data"
printf '%s\n' \
  '{"api_url":"https://dev.invalid","api_key":"cloud-config-secret"}' \
  >"$COW/cloud_sync.json"
printf 'device-fresh-identifier\n' >"$COW/data/.device_id"

{
  printf 'discarded prefix\n'
  printf 'Authorization: Bearer bearer-test-credential\n'
  printf 'api_key=cloud-config-secret\n'
  printf 'opaque=opaque-env-secret\n'
  printf 'url=https://dev.invalid/private?token=query-secret\n'
  printf '%s\n' \
    '{"ok":false,"user_hash":"22222222222222222222222222222222","report":{"manifest_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}'
  printf 'path=%s/private device-fresh-identifier digest=%s\n' \
    "$COW" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
} >"$RAW"

LASTDB_SANITIZER_TEST_TOKEN='opaque-env-secret' \
  python3 "$SANITIZER" --source "$RAW" --cow-home "$COW" \
    --lines 6 --bytes 4096 >"$SAFE"

[ "$(wc -l <"$SAFE" | tr -d ' ')" -eq 7 ] \
  || fail "the sanitizer did not enforce its six-line tail"
grep -q '^<sanitized-tail-truncated>$' "$SAFE" \
  || fail "the sanitizer did not report a truncated tail"
grep -q 'Authorization: <redacted-secret>' "$SAFE" \
  || fail "the sanitizer did not redact an authorization value"
grep -q 'api_key=<redacted-secret>' "$SAFE" \
  || fail "the sanitizer did not redact the cloud API key"
grep -q 'opaque=<redacted-secret>' "$SAFE" \
  || fail "the sanitizer did not redact a known environment secret"
grep -q 'url=<redacted-url>' "$SAFE" \
  || fail "the sanitizer did not redact a URL"
grep -q '^<redacted-snapshot-envelope>$' "$SAFE" \
  || fail "the sanitizer did not suppress a raw snapshot envelope"
grep -q 'path=<cow>/private' "$SAFE" \
  || fail "the sanitizer did not replace the full CoW path"
grep -q 'digest=<redacted-secret>' "$SAFE" \
  || fail "the sanitizer did not redact an object digest"

if grep -Eq \
    'bearer-test-credential|cloud-config-secret|opaque-env-secret|device-fresh-identifier|22222222222222222222222222222222|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "$SAFE" || grep -Fq "$COW" "$SAFE"; then
  fail "the sanitizer exposed a secret, identifier, digest, or full CoW path"
fi

ln -s "$RAW" "$TMP/raw-link.log"
python3 "$SANITIZER" --source "$TMP/raw-link.log" --cow-home "$COW" \
  --lines 6 --bytes 4096 >"$SAFE"
grep -qx '<no-log-output>' "$SAFE" \
  || fail "the sanitizer followed a log symlink"

printf 'OK: DEV photograph failure-tail sanitizer\n'
