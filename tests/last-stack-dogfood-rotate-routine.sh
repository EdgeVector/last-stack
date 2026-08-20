#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-dogfood-rotate-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/dogfood-rotate.md"
printf '%s\n' '---' 'name: dogfood-rotate' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/dogfood-rotate.toml"
test -f "$entry"
grep -q 'id = "dogfood-rotate"' "$entry"
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=11;BYMINUTE=0;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 30' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q 'last-stack-dogfood-rotate-gate --routines-dispatch' "$entry"
grep -q 'REPLACE' "$entry" && {
  echo "dogfood-rotate seed still contains REPLACE" >&2
  exit 1
}

{
  printf '%s\n' 'id = "dogfood-rotate"'
  printf '%s\n' 'status = "paused"'
  printf '%s\n' 'harness = "grok"'
  printf '%s\n' 'model = "grok-4.6"'
} >"$entry"
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"
grep -q 'status = "paused"' "$entry"
grep -q 'harness = "grok"' "$entry"
if grep -qE '^(effort|rrule) ' "$entry"; then
  echo "dogfood-rotate skip-if-exists merged compiled fields into leftover:" >&2
  cat "$entry" >&2
  exit 1
fi

ensure_out="$("$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --ensure-gate-command)"
grep -q 'updated-gate' <<<"$ensure_out"
grep -q 'status = "paused"' "$entry"
grep -q 'harness = "grok"' "$entry"
grep -q 'last-stack-dogfood-rotate-gate --routines-dispatch' "$entry"

ensure_again="$("$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --ensure-gate-command)"
grep -q 'unchanged' <<<"$ensure_again"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'dogfood-rotate.toml' <<<"$dry"
grep -q 'id = "dogfood-rotate"' <<<"$dry"
grep -q 'last-stack-dogfood-rotate-gate --routines-dispatch' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
