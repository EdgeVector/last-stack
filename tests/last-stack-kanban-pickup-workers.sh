#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-pickup-workers"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/kanban-pickup.md"
bootstrap="$tmp/prompts/last-stack-kanban-pickup-bootstrap.md"
printf '%s\n' '---' 'name: kanban-pickup' '---' >"$prompt"

"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap"

test -f "$bootstrap"
grep -q 'last-stack-routine-read" kanban-pickup' "$bootstrap"
grep -q 'last-stack-kanban-pickup-gate' "$bootstrap"
grep -q 'Zero-LLM ready gate' "$bootstrap"
grep -q 'ready=0' "$bootstrap"
grep -q 'gate_rc' "$bootstrap"
grep -q 'gateProceeded' "$bootstrap"
grep -q "$prompt" "$bootstrap"
grep -q 'routine-read-failed no_card_claimed' "$bootstrap"

for id in \
  last-stack-fkanban-pickup \
  last-stack-fkanban-pickup-w2 \
  last-stack-fkanban-pickup-w3 \
  last-stack-fkanban-pickup-w4 \
  last-stack-fkanban-pickup-w5 \
  last-stack-fkanban-pickup-w6
do
  test -f "$tmp/registry/$id.toml"
  grep -q "id = \"$id\"" "$tmp/registry/$id.toml"
  grep -q "prompt_path = \"$bootstrap\"" "$tmp/registry/$id.toml"
  grep -q 'gate_command =' "$tmp/registry/$id.toml"
  grep -q 'last-stack-kanban-pickup-gate' "$tmp/registry/$id.toml"
  grep -q 'freshness bootstrap' "$tmp/registry/$id.toml"
  grep -q 'timeout_min = 180' "$tmp/registry/$id.toml"
  grep -q 'REPLACE' "$tmp/registry/$id.toml" && {
    echo "pickup worker $id still contains REPLACE" >&2
    exit 1
  }
  grep -qE '^cwd = "' "$tmp/registry/$id.toml" || {
    echo "pickup worker $id missing cwd" >&2
    exit 1
  }
done

grep -q 'BYMINUTE=0,15,30,45;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup.toml"
grep -q 'BYMINUTE=5,20,35,50;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup-w2.toml"
grep -q 'BYMINUTE=10,25,40,55;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup-w3.toml"
grep -q 'BYMINUTE=2,17,32,47;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w4.toml"
grep -q 'BYMINUTE=7,22,37,52;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w5.toml"
grep -q 'BYMINUTE=12,27,42,57;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w6.toml"

# Existing worker files are canonical: no merge of rrule/harness on reinstall.
worker_entry="$tmp/registry/last-stack-fkanban-pickup-w3.toml"
{
  printf '%s\n' 'id = "last-stack-fkanban-pickup-w3"'
  printf '%s\n' 'harness = "grok"'
  printf '%s\n' 'model = "grok-4.5"'
  printf '%s\n' 'fallback = "claude"'
} >"$worker_entry"
before="$(cksum "$worker_entry")"
"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" >/dev/null
after="$(cksum "$worker_entry")"
test "$before" = "$after"
grep -q 'harness = "grok"' "$worker_entry"
grep -q 'model = "grok-4.5"' "$worker_entry"
grep -q 'fallback = "claude"' "$worker_entry"
if grep -q 'BYMINUTE=' "$worker_entry"; then
  echo "pickup-workers skip-if-exists merged compiled rrule into leftover:" >&2
  cat "$worker_entry" >&2
  exit 1
fi

"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" --force-defaults >/dev/null
grep -q 'harness = "codex"' "$worker_entry"
grep -q 'model = "gpt-5.5"' "$worker_entry"
grep -q 'BYMINUTE=10,25,40,55;BYSECOND=0' "$worker_entry"
if grep -q 'fallback =' "$worker_entry"; then
  echo "pickup-workers force-defaults retained leftover fallback:" >&2
  cat "$worker_entry" >&2
  exit 1
fi

before="$(cksum "$tmp/registry/last-stack-fkanban-pickup-w6.toml")"
"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" >/tmp/last-stack-pickup-workers-idempotent.$$
after="$(cksum "$tmp/registry/last-stack-fkanban-pickup-w6.toml")"
rm -f /tmp/last-stack-pickup-workers-idempotent.$$
test "$before" = "$after"

if "$BIN" --workers 7 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" >/dev/null 2>&1; then
  echo "expected invalid worker count to fail" >&2
  exit 1
fi

dry="$("$BIN" --workers 4 --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --bootstrap-path "$tmp/dry-bootstrap.md" --dry-run)"
grep -q 'dry-bootstrap.md' <<<"$dry"
grep -q 'last-stack-routine-read" kanban-pickup' <<<"$dry"
grep -q 'gateProceeded' <<<"$dry"
grep -q 'last-stack-fkanban-pickup-w4.toml' <<<"$dry"
grep -q 'id = "last-stack-fkanban-pickup-w4"' <<<"$dry"
grep -q 'gate_command' <<<"$dry"
test ! -e "$tmp/dry-registry"

echo "ok"
