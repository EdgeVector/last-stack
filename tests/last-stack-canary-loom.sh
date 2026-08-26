#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
bash -n "$BIN"
bash -n "$ROOT/lib/canary-loom/loom-canary-step.sh"
[ -f "$ROOT/lib/canary-loom/lastdb-canary-release.json" ] || fail "graph missing"
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch missing loom tick"
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood missing loom start"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export LAST_STACK_CANARY_LOOM_STAMP="$tmp/stamp.json"
out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"
out2="$("$BIN" --dry-run --start --oid abc123 --json --quiet)"
printf '%s\n' "$out2" | grep -q 'canary-abc123' || fail "start dry-run missing key: $out2"
LOOM_INPUT='{"main_oid":"abc","max_attempts":3}' "$ROOT/lib/canary-loom/loom-canary-step.sh" PROBE | grep -q 'verdict":"green"' \
  || fail "stand-in probe not green"
echo ok

[ -f "$ROOT/lib/canary-loom/lastdb-safe-upgrade.json" ] || fail "graph A missing"
