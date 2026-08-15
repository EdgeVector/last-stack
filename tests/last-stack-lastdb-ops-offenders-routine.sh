#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-ops-offenders-routine"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-lastdb-ops-offenders-routine.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || chmod +x "$BIN"

prompt="$tmp/lastdb-ops-offenders.md"
printf '%s\n' '---' 'name: lastdb-ops-offenders' '---' >"$prompt"

# dry-run must not write and must not contain REPLACE
out="$("$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --dry-run)"
printf '%s\n' "$out" | grep -q 'REPLACE' && fail "dry-run still contains REPLACE"
printf '%s\n' "$out" | grep -q 'FREQ=DAILY' || fail "dry-run missing daily rrule"
printf '%s\n' "$out" | grep -q 'BYMINUTE=40' || fail "dry-run missing :40 slot"
test ! -e "$tmp/registry/last-stack-lastdb-ops-offenders.toml" \
  || fail "dry-run wrote a registry file"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"
entry="$tmp/registry/last-stack-lastdb-ops-offenders.toml"
test -f "$entry" || fail "installer did not write entry"
grep -q 'harness = "grok"' "$entry" || fail "missing default harness"
grep -q 'model = "grok-4.5"' "$entry" || fail "missing default model"
grep -q 'effort = "medium"' "$entry" || fail "missing effort"
grep -q 'heartbeat_slug = "routine-heartbeats"' "$entry" || fail "missing heartbeat"
grep -q 'status = "active"' "$entry" || fail "missing active status"
grep -q 'REPLACE' "$entry" && fail "wrote REPLACE into registry"

{
  printf '%s\n' 'id = "last-stack-lastdb-ops-offenders"'
  printf '%s\n' 'harness = "claude"'
  printf '%s\n' 'model = "claude-sonnet-4-5"'
  printf '%s\n' 'fallback = "grok"'
} >"$entry"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
grep -q 'harness = "claude"' "$entry" || fail "should preserve existing harness"
grep -q 'model = "claude-sonnet-4-5"' "$entry" || fail "should preserve existing model"
grep -q 'fallback = "grok"' "$entry" || fail "should preserve fallback"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'harness = "grok"' "$entry" || fail "force-defaults should restore grok"
grep -q 'model = "grok-4.5"' "$entry" || fail "force-defaults should restore model"
if grep -q '^fallback = ' "$entry"; then
  echo "force-defaults retained fallback" >&2
  exit 1
fi

echo "ok last-stack-lastdb-ops-offenders-routine"
