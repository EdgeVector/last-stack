#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-red-heal-routine"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-red-routine.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/lastdb-canary-red-heal.md"
printf '%s\n' '---' 'name: lastdb-canary-red-heal' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/lastdb-canary-red-heal.toml"
test -f "$entry"
grep -q 'id = "lastdb-canary-red-heal"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=36;BYSECOND=0"' "$entry"
grep -q 'status = "paused"' "$entry"
grep -q 'timeout_min = 15' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
if grep -q 'gate_command' "$entry"; then
  echo "retired recovery lane must not install a gate" >&2
  exit 1
fi

before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'lastdb-canary-red-heal.toml' <<<"$dry"
grep -q 'id = "lastdb-canary-red-heal"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
