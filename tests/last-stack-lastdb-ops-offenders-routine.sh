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
grep -q 'difficulty = "normal"' "$entry" || fail "missing default difficulty"
grep -q 'effort = "medium"' "$entry" || fail "missing effort"
grep -q 'heartbeat_slug = "routine-heartbeats"' "$entry" || fail "missing heartbeat"
grep -q 'status = "active"' "$entry" || fail "missing active status"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=8;BYMINUTE=40;BYSECOND=0"' "$entry" \
  || fail "missing compiled daily rrule"
grep -q 'REPLACE' "$entry" && fail "wrote REPLACE into registry"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  fail "fresh ops-offenders must not emit harness/model/pin"
fi

{
  printf '%s\n' 'id = "last-stack-lastdb-ops-offenders"'
  printf '%s\n' 'difficulty = "hard"'
  printf '%s\n' 'rrule = "FREQ=DAILY;BYHOUR=16;BYMINUTE=40;BYSECOND=0"'
} >"$entry"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
grep -q 'difficulty = "hard"' "$entry" || fail "should preserve live difficulty"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=16;BYMINUTE=40;BYSECOND=0"' "$entry" \
  || fail "should preserve live rrule"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  fail "ops-offenders rewrite reintroduced harness/model/pin"
fi

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
grep -q 'difficulty = "normal"' "$entry" || fail "difficulty-mode rewrite should emit difficulty"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'difficulty = "normal"' "$entry" || fail "force-defaults should restore difficulty"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=8;BYMINUTE=40;BYSECOND=0"' "$entry" \
  || fail "force-defaults should restore compiled rrule"
if grep -qE '^(harness|model|pin|fallback) ' "$entry"; then
  echo "force-defaults retained harness/model/pin/fallback" >&2
  cat "$entry" >&2
  exit 1
fi

echo "ok last-stack-lastdb-ops-offenders-routine"
