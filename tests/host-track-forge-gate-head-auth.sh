#!/usr/bin/env bash
# host-track must read a Forgejo gate head with the forge token.
#
# Since the 2026-09-05/06 venue move every gate_main is an
# http://localhost:3300 URL. gate_head()/remote_head() ran a plain `git
# ls-remote` and discarded stderr, so an auth failure became an EMPTY gate
# head. status then reported deployment_problem="published gate head is
# unavailable" and freshness=hard_broken for a healthy install, and the canary
# build gate skipped forever with "not-stale". Brain:
# papercut-host-track-lastdb-hard-broken-when-published-head-is-unavailable-20260906
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/host-track"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/host-track-forge-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Extract the auth helper and its two callers from the real script and drive
# them directly. Asserting on executed behaviour, not on text in the file.
# From the token-lib guard down to the end of remote_head(): that block holds
# forge_auth_export and both head readers, and nothing else.
awk '/^FORGE_TOKEN_LIB_LOADED=0$/ { f = 1 }
     /^binary_version\(\) \{$/ { exit }
     f { print }' "$BIN" > "$tmp/extract.sh"
for fn in forge_auth_export gate_head remote_head; do
  grep -q "^$fn() {" "$tmp/extract.sh" || fail "could not extract $fn from $BIN"
done

cat > "$tmp/probe.sh" <<'PROBE'
set -euo pipefail
ROOT="$EXTRACT_ROOT"
. "$EXTRACT_FILE"
# Stub the token source so the test never touches the real keychain.
FORGE_TOKEN_LIB_LOADED=1
last_stack_forge_token() { printf '%s' "test-token-abc"; }
if forge_auth_export "$1" 2>/dev/null; then
  printf 'AUTH_EXPORTED\n'
  printf 'GIT_CONFIG_COUNT=%s\n' "${GIT_CONFIG_COUNT:-}"
  printf 'GIT_CONFIG_KEY_0=%s\n' "${GIT_CONFIG_KEY_0:-}"
  printf 'GIT_CONFIG_VALUE_0=%s\n' "${GIT_CONFIG_VALUE_0:-}"
else
  printf 'NO_AUTH\n'
fi
PROBE

run_probe() {
  EXTRACT_ROOT="$ROOT" EXTRACT_FILE="$tmp/extract.sh" \
    bash "$tmp/probe.sh" "$1" 2>/dev/null
}

# --- a forge remote gets the token as an env var ---
out="$(run_probe 'http://localhost:3300/EdgeVector/fold.git')"
grep -q 'AUTH_EXPORTED' <<<"$out" \
  || fail "localhost:3300 remote got no auth export: $out"
grep -q 'GIT_CONFIG_VALUE_0=Authorization: token test-token-abc' <<<"$out" \
  || fail "localhost:3300 remote got wrong GIT_CONFIG_VALUE_0: $out"

out="$(run_probe 'http://127.0.0.1:3300/EdgeVector/fold.git')"
grep -q 'AUTH_EXPORTED' <<<"$out" \
  || fail "127.0.0.1:3300 remote got no auth export: $out"
grep -q 'GIT_CONFIG_VALUE_0=Authorization: token test-token-abc' <<<"$out" \
  || fail "127.0.0.1:3300 remote got wrong token: $out"

# --- every other remote is untouched ---
for remote in \
  'https://github.com/EdgeVector/fold.git' \
  'lastdb:///fold' \
  "file://$tmp/some-repo.git" \
  'http://localhost:9999/EdgeVector/fold.git'
do
  out="$(run_probe "$remote")"
  grep -q 'NO_AUTH' <<<"$out" || fail "non-forge remote $remote gained auth: $out"
done

# --- the readers still resolve a real head over a credential-free remote ---
upstream="$tmp/upstream.git"
git init --bare "$upstream" >/dev/null 2>&1
work="$tmp/work"
git clone "$upstream" "$work" >/dev/null 2>&1
(
  cd "$work"
  git checkout -b main >/dev/null 2>&1
  echo tip > README
  git add README
  git -c user.email=t@example.com -c user.name=t commit -m tip >/dev/null
  git push origin main >/dev/null 2>&1
)
want="$(git -C "$upstream" rev-parse refs/heads/main)"

cat > "$tmp/reader.sh" <<'READER'
set -euo pipefail
ROOT="$EXTRACT_ROOT"
. "$EXTRACT_FILE"
FORGE_TOKEN_LIB_LOADED=0
gate_head "$1" "$2" "$3"
READER

# gate_head() runs git -C <dir>; give it any real repo.
got="$(EXTRACT_ROOT="$ROOT" EXTRACT_FILE="$tmp/extract.sh" \
  bash "$tmp/reader.sh" "$work" "$upstream" refs/heads/main 2>/dev/null)"
[ "$got" = "$want" ] || fail "gate_head over a plain remote: want $want got '$got'"

echo "ok host-track-forge-gate-head-auth"
