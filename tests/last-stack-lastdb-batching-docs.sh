#!/usr/bin/env bash
# Contract: the LastDB batching rule reaches every harness via setup, and the
# hourly lastdb-batch-apps routine is wired (prompt, registry, writer, README).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { printf 'lastdb-batching-docs: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }

doc="$root/instructions/lastdb-batching.md"
[ -f "$doc" ] || fail "missing $doc"
require "no serial calls" "$doc"
require "Do not write a loop" "$doc"

require "lastdb-batching.md" "$root/setup"
require "LB_START" "$root/setup"
[ "$(grep -c 'LB_START' "$root/setup")" -ge 3 ] || fail "setup must define, strip, and append LB block"

prompt="$root/routines/lastdb-batch-apps.md"
reg="$root/config/routines-registry/last-stack-lastdb-batch-apps.toml"
writer="$root/bin/last-stack-lastdb-batch-apps-routine"
[ -f "$prompt" ] && [ -f "$reg" ] && [ -x "$writer" ] || fail "routine files missing"
require "FREQ=HOURLY" "$reg"
require "Close-out (always the LAST step)" "$prompt"
require "Never file more than **one** Kind:pr card" "$prompt"
require "lastdb-batch-apps" "$root/routines/README.md"
out="$("$writer" --dry-run 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'FREQ=HOURLY' || fail "writer dry-run not hourly"
printf '%s\n' "$out" | grep -q 'REPLACE' && fail "writer dry-run contains REPLACE"
echo "lastdb-batching-docs: ok"
