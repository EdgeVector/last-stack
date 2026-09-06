#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fake_home="$tmp/home"
stub_bin="$fake_home/.local/bin"
mkdir -p "$stub_bin" "$tmp/fake-last-stack/bin"

cat > "$stub_bin/lastsecrets" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LASTSECRETS_CALLS"
if [ "${1:-}" = get ] && [ "${2:-}" = obs-sentry-auth-token ] \
   && [ -n "${LASTSECRETS_VALUE:-}" ]; then
  printf '%s\r\n' "$LASTSECRETS_VALUE"
  exit 0
fi
exit 1
STUB

cat > "$stub_bin/security" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SECURITY_CALLS"
if [ -n "${KEYCHAIN_VALUE:-}" ]; then
  printf '%s\r\n' "$KEYCHAIN_VALUE"
  exit 0
fi
exit 51
STUB

cat > "$stub_bin/brain" <<'STUB'
#!/usr/bin/env bash
cat <<'RECORD'
---
type: reference
slug: signal-sources
---
### sentry
- **scopes**: `edge-vector/demo-project`
RECORD
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS"
headers=""
body=""
auth=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) headers="$2"; shift 2 ;;
    -o) body="$2"; shift 2 ;;
    -H) auth="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -s|-sS) shift ;;
    *) shift ;;
  esac
done
[ "$auth" = "Authorization: Bearer from-lastsecrets" ] || exit 8
if [ -n "$headers" ]; then
  printf '%s\n' 'HTTP/2 200' > "$headers"
fi
if [ -n "$body" ]; then
  printf '%s\n' '[]' > "$body"
else
  printf '%s\n' '[]'
fi
STUB

cat > "$tmp/fake-last-stack/bin/last-stack-brain-append-heartbeat" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HEARTBEAT_CALLS"
STUB
chmod +x "$stub_bin/lastsecrets" "$stub_bin/security" "$stub_bin/brain" \
  "$stub_bin/curl" "$tmp/fake-last-stack/bin/last-stack-brain-append-heartbeat"

export HOME="$fake_home"
export PATH="$stub_bin:/usr/bin:/bin"
export LASTSECRETS_CALLS="$tmp/lastsecrets.calls"
export SECURITY_CALLS="$tmp/security.calls"
export CURL_CALLS="$tmp/curl.calls"
export HEARTBEAT_CALLS="$tmp/heartbeat.calls"
touch "$LASTSECRETS_CALLS" "$SECURITY_CALLS" "$CURL_CALLS" "$HEARTBEAT_CALLS"

awk '/# sentry-token-bootstrap:start/{copy=1} copy{print} \
  /# sentry-token-bootstrap:end/{exit}' "$ROOT/routines/sentry-triage.md" \
  > "$tmp/prompt-bootstrap.sh"
printf '%s\n' 'printf "TOKEN=%s\\n" "$TOKEN"' >> "$tmp/prompt-bootstrap.sh"

prompt_out="$(SENTRY_AUTH_TOKEN= LASTSECRETS_VALUE=from-lastsecrets \
  KEYCHAIN_VALUE= last_stack="$tmp/fake-last-stack" \
  bash "$tmp/prompt-bootstrap.sh")"
[ "$prompt_out" = "TOKEN=from-lastsecrets" ] \
  || fail "prompt must use the newline-free LastSecrets value: $prompt_out"
[ ! -s "$SECURITY_CALLS" ] \
  || fail "prompt must not read the keychain after LastSecrets succeeds"

# If the token is empty, this synthetic first Sentry call must stay unreachable.
printf '%s\n' 'curl -sS https://sentry.invalid/api/0/projects/' \
  >> "$tmp/prompt-bootstrap.sh"
: > "$LASTSECRETS_CALLS"
: > "$SECURITY_CALLS"
: > "$CURL_CALLS"
prompt_out="$(SENTRY_AUTH_TOKEN= LASTSECRETS_VALUE= KEYCHAIN_VALUE= \
  last_stack="$tmp/fake-last-stack" bash "$tmp/prompt-bootstrap.sh")"
printf '%s\n' "$prompt_out" | grep -q \
  'ROUTINE_RESULT outcome=error detail=sentry_token_unreadable auth_ref=lastsecrets://obs-sentry-auth-token cards=0' \
  || fail "prompt must name sentry_token_unreadable before any Sentry call"
[ ! -s "$CURL_CALLS" ] || fail "the unreadable-token path must make zero HTTP calls"

: > "$SECURITY_CALLS"
: > "$CURL_CALLS"
usage_out="$(SENTRY_AUTH_TOKEN= LASTSECRETS_VALUE=from-lastsecrets \
  KEYCHAIN_VALUE= "$ROOT/skills/morning-sync/usage-bugs.sh" sentry)"
printf '%s\n' "$usage_out" | grep -q '\*\*demo-project\*\*: 0 unresolved' \
  || fail "morning-sync must query Sentry with the LastSecrets token: $usage_out"
[ ! -s "$SECURITY_CALLS" ] \
  || fail "morning-sync must not read the keychain after LastSecrets succeeds"
[ -s "$CURL_CALLS" ] || fail "morning-sync must call Sentry with a token"

printf 'ok: sentry token uses env > lastsecrets > keychain; empty prompt path makes zero HTTP calls\n'
