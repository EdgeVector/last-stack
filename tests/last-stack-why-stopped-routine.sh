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
grep -q 'harness = "grok"' "$entry"
grep -q 'model = "grok-4.5"' "$entry"
grep -q 'effort = "low"' "$entry"

{
  printf '%s\n' 'id = "last-stack-why-stopped"'
  printf '%s\n' 'harness = "claude"'
  printf '%s\n' 'model = "claude-sonnet-4-5"'
  printf '%s\n' 'fallback = "grok"'
} >"$entry"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
grep -q 'harness = "claude"' "$entry"
grep -q 'model = "claude-sonnet-4-5"' "$entry"
grep -q 'fallback = "grok"' "$entry"
grep -q 'heartbeat_slug = "routine-heartbeats"' "$entry"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'harness = "grok"' "$entry"
grep -q 'model = "grok-4.5"' "$entry"
if grep -q '^fallback = ' "$entry"; then
  echo "why-stopped force-defaults retained fallback" >&2
  exit 1
fi

echo "ok"
