#!/usr/bin/env bash
# The forge token must survive a locked login keychain.
#
# On 2026-09-06 the login keychain locked to non-interactive readers.
# `security find-generic-password -s forgejo-token -w` exited 51 and printed
# NOTHING, so last-stack-forge-api, last-stack-forge-git and
# last-stack-portal-wt all failed at once and no unattended agent could push,
# open a PR, or even fetch a portal tip — on the day Forgejo became the gate of
# record for last-stack, fkanban, routines and loom. Five routines hit it in
# one night.
#
# Papercut: papercut-forge-helpers-keychain-lockout-blocks-unattended-push
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/stub"
PATH="$tmp/stub:$PATH"
export PATH

# `security` stands in for the keychain. KEYCHAIN_VALUE empty => locked: exit
# 51 with an empty stderr, exactly as the real lockout behaves.
cat > "$tmp/stub/security" <<'STUB'
#!/usr/bin/env bash
if [ -n "${KEYCHAIN_VALUE:-}" ]; then
  printf '%s\n' "$KEYCHAIN_VALUE"
  exit 0
fi
exit 51
STUB
cat > "$tmp/stub/lastsecrets" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = forgejo-token ] && [ -n "${LASTSECRETS_VALUE:-}" ]; then
  printf '%s\n' "$LASTSECRETS_VALUE"
  exit 0
fi
echo "lastsecrets: secret not found: ${2:-}" >&2
exit 1
STUB
chmod +x "$tmp/stub/security" "$tmp/stub/lastsecrets"

# shellcheck source=../lib/forge-token.sh
. "$ROOT/lib/forge-token.sh"

# --- 1. $FORGE_TOKEN wins ---------------------------------------------------
got="$(FORGE_TOKEN=from-env KEYCHAIN_VALUE=from-keychain \
  LASTSECRETS_VALUE=from-lastsecrets last_stack_forge_token || true)"
[ "$got" = "from-env" ] || fail "FORGE_TOKEN must win, got '$got'"

# --- 2. keychain outranks lastsecrets ---------------------------------------
# An operator rotating the keychain locally must not be overridden by a stale
# stored fallback.
got="$(KEYCHAIN_VALUE=from-keychain LASTSECRETS_VALUE=from-lastsecrets \
  last_stack_forge_token || true)"
[ "$got" = "from-keychain" ] || fail "keychain must outrank lastsecrets, got '$got'"

# --- 3. THE REGRESSION: locked keychain falls back to lastsecrets -----------
got="$(KEYCHAIN_VALUE= LASTSECRETS_VALUE=from-lastsecrets last_stack_forge_token || true)"
[ "$got" = "from-lastsecrets" ] \
  || fail "a locked keychain (rc 51) must fall back to lastsecrets, got '$got'"

# --- 4. no source at all: non-zero, and the message names all three ---------
if got="$(KEYCHAIN_VALUE= LASTSECRETS_VALUE= last_stack_forge_token)"; then
  fail "no source must return non-zero, got '$got'"
fi
msg="$(last_stack_forge_token_missing_msg 2>&1)"
for needle in 'FORGE_TOKEN' 'keychain' 'lastsecrets'; do
  printf '%s\n' "$msg" | grep -q "$needle" \
    || fail "missing-token message must name $needle, got: $msg"
done
# The message must not send a reader to the keychain without saying the
# keychain is the thing that breaks.
printf '%s\n' "$msg" | grep -q 'locked' \
  || fail "missing-token message must name the locked-keychain case"

# --- 5. every forge helper resolves through the shared function -------------
# A helper that keeps its own copy of the keychain read is the defect coming
# back one file at a time.
for h in bin/last-stack-forge-api bin/last-stack-forge-git; do
  grep -q 'last_stack_forge_token' "$ROOT/$h" \
    || fail "$h must resolve its token through last_stack_forge_token"
  grep -q 'find-generic-password' "$ROOT/$h" \
    && fail "$h must not read the keychain directly; use lib/forge-token.sh"
done
grep -q 'last_stack_forge_token' "$ROOT/bin/last-stack-portal-wt" \
  || fail "portal-wt must authenticate forge fetches through last_stack_forge_token"

printf 'ok: forge token fallback (env > keychain > lastsecrets, locked keychain, shared resolver)\n'
