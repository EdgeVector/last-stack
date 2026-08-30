#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-fleet-performance-routine"
PROMPT="$ROOT/routines/fleet-performance.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

grep -q 'mechanical no-op' "$PROMPT"
grep -q 'agent no-op share' "$PROMPT"
grep -q 'Use only the agent no-op share for model-waste decisions' "$PROMPT"

chmod +x "$BIN"
prompt="$tmp/fleet-performance.md"
printf '%s\n' '---' 'name: fleet-performance' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/last-stack-fleet-performance.toml"
test -f "$entry" || { echo "did not write entry" >&2; exit 1; }
grep -q 'id = "last-stack-fleet-performance"' "$entry"
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=7;BYMINUTE=10;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 30' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  echo "installer must not emit harness/model/pin:" >&2
  cat "$entry" >&2
  exit 1
fi
grep -q 'REPLACE' "$entry" && { echo "wrote unsubstituted REPLACE" >&2; exit 1; }
if grep -q 'Users/REPLACE' "$entry"; then
  echo "emitted registry still contains Users/REPLACE:" >&2
  cat "$entry" >&2
  exit 1
fi
expected_cwd="${LAST_STACK_WORKSPACE:-${HOME%/}/code/edgevector}"
grep -q "cwd = \"$expected_cwd\"" "$entry"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
printf '%s\n' "$dry" | grep -q 'REPLACE' && { echo "dry-run contains REPLACE" >&2; exit 1; }
printf '%s\n' "$dry" | grep -q "cwd = \"$expected_cwd\""
test ! -e "$tmp/dry-registry"

# Reinstall leaves a live cadence/difficulty/status slice byte-for-byte alone.
{
  printf '%s\n' 'id = "last-stack-fleet-performance"'
  printf '%s\n' 'difficulty = "fast"'
  printf '%s\n' 'rrule = "FREQ=DAILY;BYHOUR=16;BYMINUTE=5;BYSECOND=0"'
  printf '%s\n' 'status = "paused"'
  printf '%s\n' "prompt_path = \"$prompt\""
} >"$entry"
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"
grep -q 'difficulty = "fast"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=16;BYMINUTE=5;BYSECOND=0"' "$entry"
grep -q 'status = "paused"' "$entry"
if grep -qE '^(harness|model|pin|effort) ' "$entry"; then
  echo "reinstall mutated a live file:" >&2
  cat "$entry" >&2
  exit 1
fi

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=7;BYMINUTE=10;BYSECOND=0"' "$entry"
grep -q 'status = "active"' "$entry"

before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
