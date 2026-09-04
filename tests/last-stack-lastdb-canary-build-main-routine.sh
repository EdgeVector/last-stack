#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-canary-build-main-routine"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-build-main-routine.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/lastdb-canary-build-main.md"
printf '%s\n' '---' 'name: lastdb-canary-build-main' '---' >"$prompt"
gate="$tmp/last-stack-canary-build-main-gate"
printf '#!/bin/sh\nexit 10\n' >"$gate"
chmod +x "$gate"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate"

entry="$tmp/registry/lastdb-canary-build-main.toml"
test -f "$entry"
grep -q 'id = "lastdb-canary-build-main"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=47;BYSECOND=0"' "$entry"
grep -q 'status = "active"' "$entry"
grep -q 'timeout_min = 180' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
grep -q "gate_command = \"$gate\"" "$entry"

# Seed-if-missing: unchanged on a second run.
before="$(cksum "$entry")"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate" >/dev/null
after="$(cksum "$entry")"
test "$before" = "$after"

# Dry run writes nothing.
dry="$("$BIN" --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --gate-path "$gate" --dry-run)"
grep -q 'lastdb-canary-build-main.toml' <<<"$dry"
grep -q 'id = "lastdb-canary-build-main"' <<<"$dry"
test ! -e "$tmp/dry-registry"

# Missing prompt fails loudly instead of seeding a broken entry.
if "$BIN" --registry-dir "$tmp/registry2" --prompt-path "$tmp/missing.md" --gate-path "$gate" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
