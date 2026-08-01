#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-validate-routine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/kanban-validate.md"
printf '%s\n' '---' 'name: kanban-validate' '---' >"$prompt"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt"

entry="$tmp/registry/last-stack-fkanban-validate.toml"
test -f "$entry"
grep -q 'id = "last-stack-fkanban-validate"' "$entry"
grep -q 'harness = "codex"' "$entry"
grep -q 'effort = "medium"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=4;BYMINUTE=33;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 30' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q 'terminal North Star proof' "$entry"

before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/tmp/last-stack-kanban-validate-idempotent.$$
after="$(cksum "$entry")"
rm -f /tmp/last-stack-kanban-validate-idempotent.$$
test "$before" = "$after"

dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --dry-run)"
grep -q 'last-stack-fkanban-validate.toml' <<<"$dry"
grep -q 'id = "last-stack-fkanban-validate"' <<<"$dry"
test ! -e "$tmp/dry-registry"

if "$BIN" --registry-dir "$tmp/registry" --prompt-path "$tmp/missing.md" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
