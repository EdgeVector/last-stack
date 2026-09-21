#!/usr/bin/env bash
# The deploy-watch seeder writes the 5-minute entry once and never rewrites it.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-deploy-watch-routine"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-candidate-set-routine.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/deploy-watch.md"
printf '%s\n' '---' 'name: deploy-watch' '---' >"$prompt"
gate="$tmp/last-stack-deploy-watch-gate"
printf '#!/bin/sh\nexit 0\n' >"$gate"
chmod +x "$gate"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate"

entry="$tmp/registry/deploy-watch.toml"
test -f "$entry"
grep -q 'id = "deploy-watch"' "$entry"
grep -q 'rrule = "FREQ=MINUTELY;INTERVAL=5;BYSECOND=0"' "$entry"
grep -q 'status = "active"' "$entry"
grep -q 'timeout_min = 30' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q "gate_command = \"$gate\"" "$entry"

# Seed-if-missing: unchanged on a second run.
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"

# Dry run writes nothing.
dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --gate-path "$gate" --dry-run)"
grep -q 'deploy-watch.toml' <<<"$dry"
test ! -e "$tmp/dry-registry"

# Missing prompt fails loudly instead of seeding a broken entry.
if "$BIN" --registry-dir "$tmp/registry2" --prompt-path "$tmp/missing.md" --gate-path "$gate" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
