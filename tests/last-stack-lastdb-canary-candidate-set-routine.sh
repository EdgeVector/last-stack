#!/usr/bin/env bash
# The candidate-set seeder writes the nightly entry once, never rewrites it,
# and retires the four superseded canary entries only when asked.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-canary-candidate-set-routine"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-candidate-set-routine.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/lastdb-canary-candidate-set.md"
printf '%s\n' '---' 'name: lastdb-canary-candidate-set' '---' >"$prompt"
gate="$tmp/last-stack-canary-candidate-gate"
printf '#!/bin/sh\nexit 0\n' >"$gate"
chmod +x "$gate"

"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate"

entry="$tmp/registry/lastdb-canary-candidate-set.toml"
test -f "$entry"
grep -q 'id = "lastdb-canary-candidate-set"' "$entry"
grep -q 'rrule = "FREQ=DAILY;BYHOUR=2;BYMINUTE=47;BYSECOND=0"' "$entry"
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
grep -q 'lastdb-canary-candidate-set.toml' <<<"$dry"
test ! -e "$tmp/dry-registry"

# Superseded entries stay untouched without --retire-superseded, and are
# paused (with a backup) with it. A second retire is a no-op.
for old in lastdb-canary-build-main lastdb-canary-dogfood lastdb-canary-promote-prepare lastdb-canary-red-heal; do
  printf 'id = "%s"\nstatus = "active"\ntimeout_min = 90\n' "$old" >"$tmp/registry/$old.toml"
done
"$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate" >/dev/null
grep -q 'status = "active"' "$tmp/registry/lastdb-canary-dogfood.toml" || { echo "retired without the flag" >&2; exit 1; }
out="$("$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate" --retire-superseded)"
for old in lastdb-canary-build-main lastdb-canary-dogfood lastdb-canary-promote-prepare lastdb-canary-red-heal; do
  grep -q '^status = "paused"  # superseded by lastdb-canary-candidate-set' "$tmp/registry/$old.toml" || { echo "$old not retired" >&2; exit 1; }
  grep -q 'timeout_min = 90' "$tmp/registry/$old.toml" || { echo "$old lost its other lines" >&2; exit 1; }
  ls "$tmp/registry/$old.toml.bak-retired-"* >/dev/null 2>&1 || { echo "$old has no backup" >&2; exit 1; }
done
grep -q 'retired ' <<<"$out"
out2="$("$BIN" --registry-dir "$tmp/registry" --prompt-path "$prompt" --gate-path "$gate" --retire-superseded)"
grep -q 'already retired' <<<"$out2"
grep -q '^retired ' <<<"$out2" && { echo "second retire rewrote entries" >&2; exit 1; }

# Missing prompt fails loudly instead of seeding a broken entry.
if "$BIN" --registry-dir "$tmp/registry2" --prompt-path "$tmp/missing.md" --gate-path "$gate" >/dev/null 2>&1; then
  echo "expected missing prompt to fail" >&2
  exit 1
fi

echo "ok"
