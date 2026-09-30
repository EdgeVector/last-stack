#!/usr/bin/env bash
# SMOKE_NO_FORGE_AUTH=1 must skip the Forge token lookup in the llms.txt smoke,
# and the default (flag unset) must still do the lookup. The block in run.sh is
# fenced by forge-auth-block-begin/end markers; this test runs only that block
# against a stub forge-token.sh that records each call.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
RUN="$ROOT/skills/llms-txt-install-smoke/run.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/smoke-no-forge-auth.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/root/lib"
cat > "$tmp/root/lib/forge-token.sh" <<STUB
last_stack_forge_token() {
  printf 'called\n' >> "$tmp/calls.txt"
  printf 'tok-stub-not-a-secret\n'
}
STUB

sed -n '/^# forge-auth-block-begin$/,/^# forge-auth-block-end$/p' "$RUN" > "$tmp/block.sh"
[ -s "$tmp/block.sh" ] || fail "markers missing in run.sh"
grep -q 'SMOKE_NO_FORGE_AUTH' "$tmp/block.sh" || fail "block does not read SMOKE_NO_FORGE_AUTH"

# run_block <flag value or empty>; prints "<lookup calls> <GIT_CONFIG_COUNT|none>"
run_block() {
  rm -f "$tmp/calls.txt"
  local flag="${1:-}" out calls
  out="$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u SMOKE_NO_FORGE_AUTH \
    SMOKE_NO_FORGE_AUTH_TEST="$flag" \
    REAL_HOME="$tmp/home" LAST_STACK_ROOT="$tmp/root" SMOKE_SELF_DIR="$tmp/none" \
    SMOKE_CANDIDATE_SET="$tmp/set.json" \
    bash -c '[ -z "$SMOKE_NO_FORGE_AUTH_TEST" ] || export SMOKE_NO_FORGE_AUTH="$SMOKE_NO_FORGE_AUTH_TEST"; . "$1"; printf "%s\n" "${GIT_CONFIG_COUNT:-none}"' _ "$tmp/block.sh")"
  calls=0
  [ ! -f "$tmp/calls.txt" ] || calls="$(wc -l < "$tmp/calls.txt" | tr -d ' ')"
  printf '%s %s\n' "$calls" "$out"
}

[ "$(run_block "")" = "1 1" ] || fail "default must look up the token (got: $(run_block ""))"
[ "$(run_block 1)" = "0 none" ] || fail "SMOKE_NO_FORGE_AUTH=1 must skip the lookup (got: $(run_block 1))"
[ "$(run_block 0)" = "1 1" ] || fail "SMOKE_NO_FORGE_AUTH=0 must keep the default (got: $(run_block 0))"

printf 'ok llms-txt-smoke-no-forge-auth\n'
