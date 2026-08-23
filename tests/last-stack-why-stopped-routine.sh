#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-why-stopped-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/why-stopped.md"
printf '%s\n' '---' 'name: why-stopped' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"
entry="$tmp/registry/last-stack-why-stopped.toml"
grep -q 'difficulty = "normal"' "$entry"
grep -q 'effort = "low"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=2;BYMINUTE=11;BYSECOND=0"' "$entry"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  echo "fresh why-stopped must not emit harness/model/pin:" >&2
  cat "$entry" >&2
  exit 1
fi

{
  printf '%s\n' 'id = "last-stack-why-stopped"'
  printf '%s\n' 'difficulty = "fast"'
  printf '%s\n' 'rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=11;BYSECOND=0"'
} >"$entry"
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"
grep -q 'difficulty = "fast"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=11;BYSECOND=0"' "$entry"
if grep -qE '^(harness|model|pin|effort) ' "$entry"; then
  echo "why-stopped rewrite mutated a live file:" >&2
  cat "$entry" >&2
  exit 1
fi

{
  printf '%s\n' 'id = "last-stack-why-stopped"'
  printf '%s\n' 'harness = "claude"'
  printf '%s\n' 'model = "claude-sonnet-4-5"'
  printf '%s\n' 'fallback = "grok"'
} >"$entry"
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"
grep -q 'harness = "claude"' "$entry"
grep -q 'model = "claude-sonnet-4-5"' "$entry"
grep -q 'fallback = "grok"' "$entry"
if grep -qE '^(difficulty|heartbeat_slug) ' "$entry"; then
  echo "why-stopped skip-if-exists merged compiled fields into leftover:" >&2
  cat "$entry" >&2
  exit 1
fi

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=2;BYMINUTE=11;BYSECOND=0"' "$entry"
if grep -qE '^(harness|model|pin|fallback) ' "$entry"; then
  echo "why-stopped force-defaults retained harness/model/pin/fallback" >&2
  cat "$entry" >&2
  exit 1
fi

echo "ok"
