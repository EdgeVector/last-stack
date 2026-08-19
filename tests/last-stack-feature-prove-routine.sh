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
grep -q 'difficulty = "normal"' "$entry"
grep -q 'effort = "high"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=10;BYMINUTE=40;BYSECOND=0"' "$entry"
grep -q 'timeout_min = 45' "$entry"
grep -q "prompt_path = \"$prompt\"" "$entry"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  echo "fresh feature-prove must not emit harness/model/pin:" >&2
  cat "$entry" >&2
  exit 1
fi
grep -q 'REPLACE' "$entry" && { echo "feature-prove wrote unsubstituted REPLACE" >&2; exit 1; }
grep -qE '^cwd = "' "$entry" || { echo "feature-prove missing cwd" >&2; exit 1; }

# cwd must be install-time rendered — never the /Users/REPLACE template.
if grep -q 'Users/REPLACE' "$entry"; then
  echo "emitted registry still contains Users/REPLACE:" >&2
  cat "$entry" >&2
  exit 1
fi
expected_cwd="${LAST_STACK_WORKSPACE:-${HOME%/}/code/edgevector}"
grep -q "cwd = \"$expected_cwd\"" "$entry"

# dry-run also must not print the unreplaced template
dry_cwd="$("$BIN" --registry-dir "$tmp/dry-registry-cwd" --prompt-path "$prompt" --dry-run)"
if grep -q 'Users/REPLACE' <<<"$dry_cwd"; then
  echo "dry-run output still contains Users/REPLACE:" >&2
  printf '%s\n' "$dry_cwd" >&2
  exit 1
fi
grep -q "cwd = \"$expected_cwd\"" <<<"$dry_cwd"

# A reinstall preserves a live daily+difficulty slice (fleet-performance
# heal) and does not reintroduce harness/model.
{
  printf '%s\n' 'id = "last-stack-feature-prove"'
  printf '%s\n' 'difficulty = "normal"'
  printf '%s\n' 'rrule = "FREQ=DAILY;BYHOUR=10;BYMINUTE=40;BYSECOND=0"'
} >"$entry"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=10;BYMINUTE=40;BYSECOND=0"' "$entry"
if grep -qE '^(harness|model|pin) ' "$entry"; then
  echo "feature-prove rewrite reintroduced harness/model/pin:" >&2
  cat "$entry" >&2
  exit 1
fi

# Existing harness/model keys (smoke leftover) are preserved, not stomped.
{
  printf '%s\n' 'id = "last-stack-feature-prove"'
  printf '%s\n' 'harness = "claude"'
  printf '%s\n' 'model = "claude-opus-4-1"'
  printf '%s\n' 'fallback = "grok"'
  printf '%s\n' 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=40;BYSECOND=0"'
} >"$entry"
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" >/dev/null
grep -q 'harness = "claude"' "$entry"
grep -q 'model = "claude-opus-4-1"' "$entry"
grep -q 'fallback = "grok"' "$entry"
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=HOURLY;INTERVAL=1;BYMINUTE=40;BYSECOND=0"' "$entry"
grep -q 'effort = "high"' "$entry"

# Explicit force restores compiled daily+difficulty and drops pin keys.
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --force-defaults >/dev/null
grep -q 'difficulty = "normal"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=10;BYMINUTE=40;BYSECOND=0"' "$entry"
if grep -qE '^(harness|model|pin|fallback) ' "$entry"; then
  echo "feature-prove force-defaults retained harness/model/pin/fallback" >&2
  cat "$entry" >&2
  exit 1
fi
# override via LAST_STACK_WORKSPACE
override_cwd="$tmp/custom-workspace"
mkdir -p "$override_cwd"
override_out="$(
  LAST_STACK_WORKSPACE="$override_cwd" \
    "$BIN" --registry-dir "$tmp/registry-override" --prompt-path "$prompt" --dry-run
)"
grep -q "cwd = \"$override_cwd\"" <<<"$override_out"
if grep -q 'Users/REPLACE' <<<"$override_out"; then
  echo "override dry-run still contains Users/REPLACE" >&2
  exit 1
fi

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
