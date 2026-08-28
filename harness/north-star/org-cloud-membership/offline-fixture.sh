#!/usr/bin/env bash
# Offline fixture for north-star-org-cloud-principal-membership.
# Lives under harness/ so Host Track artifacts pack it (.lastgit/artifacts.json
# does not pack tests/). Keep the live dogfood binary on
# bin/last-stack-org-cloud-membership-dogfood.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
BIN="$ROOT/bin/last-stack-org-cloud-membership-dogfood"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/org-cloud-membership-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/out"

fail() {
  echo "last-stack-org-cloud-membership-dogfood: $*" >&2
  exit 1
}

cat >"$WORK/bin/lastsecrets" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  owner-key) printf '%s\n' 'fixture-owner-secret-value' ;;
  member-key) printf '%s\n' 'fixture-member-secret-value' ;;
  org-demo-e2e) printf '%s\n' 'fixture-shared-e2e-value' ;;
  *) exit 1 ;;
esac
EOF

cat >"$WORK/bin/org" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$ORG_FIXTURE_LOG"
case "${1:-} ${2:-}" in
  'show demo') printf '%s\n' 'slug=demo org_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa role=owner' ;;
  'member grant') exit 0 ;;
  'member revoke') exit 0 ;;
  *) exit 2 ;;
esac
EOF

cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
printf '%s\n' "$*" >>"$CURL_ARG_LOG"
out=""
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    --write-out) shift 2 ;;
    --config) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ -n "$body" ]
action="$(jq -r .action "$body")"
count=0
[ ! -f "$CURL_COUNT_FILE" ] || count="$(cat "$CURL_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$CURL_COUNT_FILE"

case "$config:$action:$count" in
  *fixture-member-secret-value*:list_objects:1)
    if [ "${ORG_FIXTURE_FAIL_AFTER_GRANT:-0}" = "1" ]; then
      exit 22
    fi
    printf '%s\n' '{"ok":true,"objects":[{"key":"log/7.enc"}]}' >"$out"
    printf '200'
    ;;
  *fixture-member-secret-value*:presign_log_download:2)
    printf '%s\n' '{"ok":true,"urls":[{"method":"GET"}]}' >"$out"
    printf '200'
    ;;
  *fixture-member-secret-value*:list_objects:3)
    printf '%s\n' '{"ok":false,"code":"FORBIDDEN","statusCode":403}' >"$out"
    printf '403'
    ;;
  *fixture-owner-secret-value*:list_objects:4)
    printf '%s\n' '{"ok":true,"objects":[]}' >"$out"
    printf '200'
    ;;
  *) exit 23 ;;
esac
EOF

chmod +x "$WORK/bin/lastsecrets" "$WORK/bin/org" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export ORG_CLI=org
export LASTSECRETS_CLI=lastsecrets
export CURL_BIN=curl
export ORG_CLOUD_MEMBERSHIP_ALLOW_FAKE_SOCKET=1
export ORG_FIXTURE_LOG="$WORK/org.log"
export CURL_ARG_LOG="$WORK/curl-args.log"
export CURL_COUNT_FILE="$WORK/curl-count"

artifact="$WORK/out/proof.md"
"$BIN" \
  --org-slug demo \
  --member-user-hash memberprincipal0001 \
  --owner-api-key-ref lastsecrets://owner-key \
  --member-api-key-ref lastsecrets://member-key \
  --storage-url https://storage.example.test \
  --owner-socket "$WORK/fake.sock" \
  --artifact "$artifact" >/dev/null

head -n 1 "$artifact" | grep -q '^PASS '
grep -q '^grant=ok role=reader$' "$artifact"
grep -q '^member_after_grant=list-and-presign-ok$' "$artifact"
grep -q '^member_after_revoke=effective-http-403$' "$artifact"
grep -q '^owner_after_revoke=list-ok$' "$artifact"
grep -q '^e2e_key_unchanged=true$' "$artifact"
if rg -n 'fixture-(owner|member|shared)' "$artifact" "$CURL_ARG_LOG"; then
  fail "secret value leaked to artifact or curl argv"
fi
grep -q '^member grant demo memberprincipal0001 --role reader --socket-path ' "$ORG_FIXTURE_LOG"
grep -q '^member revoke demo memberprincipal0001 --socket-path ' "$ORG_FIXTURE_LOG"

rm -f "$CURL_COUNT_FILE" "$ORG_FIXTURE_LOG"
export ORG_FIXTURE_FAIL_AFTER_GRANT=1
if "$BIN" \
  --org-slug demo \
  --member-user-hash memberprincipal0001 \
  --owner-api-key-ref lastsecrets://owner-key \
  --member-api-key-ref lastsecrets://member-key \
  --storage-url https://storage.example.test \
  --owner-socket "$WORK/fake.sock" \
  --artifact "$WORK/out/fail.md" >/dev/null 2>&1; then
  fail "fault-injected request unexpectedly passed"
fi
head -n 1 "$WORK/out/fail.md" | grep -q '^FAIL '
grant_line="$(grep -n '^member grant ' "$ORG_FIXTURE_LOG" | cut -d: -f1)"
revoke_line="$(grep -n '^member revoke ' "$ORG_FIXTURE_LOG" | tail -n 1 | cut -d: -f1)"
[ "$grant_line" -lt "$revoke_line" ] || fail "failure cleanup did not revoke after grant"

"$BIN" --help | grep -q '^usage:'
echo "PASS last-stack-org-cloud-membership-dogfood"
