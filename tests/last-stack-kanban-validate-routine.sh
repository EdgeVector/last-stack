#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-validate-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/kanban-validate.md"
printf '%s\n' '---' 'name: kanban-validate' '---' >"$prompt"

"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/last-stack-fkanban-validate.toml"
test -f "$entry"
grep -q 'id = "last-stack-fkanban-validate"' "$entry"
grep -q 'harness = "codex"' "$entry"
grep -q 'effort = "medium"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;BYMINUTE=0,15,30,45;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 30' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q 'terminal North Star proof' "$entry"

for id in \
  last-stack-fkanban-validate \
  last-stack-fkanban-validate-w2 \
  last-stack-fkanban-validate-w3 \
  last-stack-fkanban-validate-w4 \
  last-stack-fkanban-validate-w5 \
  last-stack-fkanban-validate-w6
do
  test -f "$tmp/registry/$id.toml"
  grep -q "id = \"$id\"" "$tmp/registry/$id.toml"
  grep -q "prompt_path = \"$prompt\"" "$tmp/registry/$id.toml"
  grep -q 'timeout_min = 30' "$tmp/registry/$id.toml"
done

grep -q 'BYMINUTE=5,20,35,50;BYSECOND=0' "$tmp/registry/last-stack-fkanban-validate-w2.toml"
grep -q 'BYMINUTE=10,25,40,55;BYSECOND=0' "$tmp/registry/last-stack-fkanban-validate-w3.toml"
grep -q 'BYMINUTE=2,17,32,47;BYSECOND=30' "$tmp/registry/last-stack-fkanban-validate-w4.toml"
grep -q 'BYMINUTE=7,22,37,52;BYSECOND=30' "$tmp/registry/last-stack-fkanban-validate-w5.toml"
grep -q 'BYMINUTE=12,27,42,57;BYSECOND=30' "$tmp/registry/last-stack-fkanban-validate-w6.toml"

{
  printf '%s\n' 'id = "last-stack-fkanban-validate"'
  printf '%s\n' 'harness = "grok"'
  printf '%s\n' 'model = "grok-4.5"'
  printf '%s\n' 'fallback = "claude"'
} >"$entry"
before="$(cksum "$entry")"
"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"
grep -q 'harness = "grok"' "$entry"
grep -q 'model = "grok-4.5"' "$entry"
grep -q 'fallback = "claude"' "$entry"
if grep -qE '^(effort|rrule) ' "$entry"; then
  echo "kanban-validate skip-if-exists merged compiled fields into leftover:" >&2
  cat "$entry" >&2
  exit 1
fi

before="$(cksum "$entry")"
"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" >/tmp/last-stack-kanban-validate-idempotent.$$
after="$(cksum "$entry")"
rm -f /tmp/last-stack-kanban-validate-idempotent.$$
test "$before" = "$after"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'last-stack-fkanban-validate.toml' <<<"$dry"
grep -q 'id = "last-stack-fkanban-validate"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --workers 7 --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null 2>&1; then
  echo "expected invalid worker count to fail" >&2
  exit 1
fi

dry="$("$BIN" --workers 4 --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'last-stack-fkanban-validate-w4.toml' <<<"$dry"
grep -q 'id = "last-stack-fkanban-validate-w4"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
