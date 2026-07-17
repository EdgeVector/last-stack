#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-feature-prove-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/feature-prove.md"
printf '%s\n' '---' 'name: feature-prove' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/last-stack-feature-prove.toml"
test -f "$entry"
grep -q 'id = "last-stack-feature-prove"' "$entry"
grep -q 'harness = "codex"' "$entry"
grep -q 'effort = "high"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=40;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 45' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"

before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/tmp/last-stack-feature-prove-idempotent.$$
after="$(cksum "$entry")"
rm -f /tmp/last-stack-feature-prove-idempotent.$$
test "$before" = "$after"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'last-stack-feature-prove.toml' <<<"$dry"
grep -q 'id = "last-stack-feature-prove"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
