#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-whats-wrong-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/whats-wrong.md"
printf '%s\n' '---' 'name: whats-wrong' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/last-stack-whats-wrong.toml"
test -f "$entry"
grep -q 'id = "last-stack-whats-wrong"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=23;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 45' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q 'bin/last-stack-whats-wrong-loom' "$entry"
if grep -q 'observer-gate last-stack-whats-wrong' "$entry"; then
  echo "gate_command must be the healer, not observer-gate --status" >&2
  exit 1
fi

before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'last-stack-whats-wrong.toml' <<<"$dry"
grep -q 'id = "last-stack-whats-wrong"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
