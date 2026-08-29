#!/usr/bin/env bash
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
DEADLINE="$ROOT/skills/lastdb-safe-upgrade/scripts/deadline.sh"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/deadline.sh
. "$DEADLINE"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
}

grep -Fq 'deadline.sh' "$DRIVER" \
  || fail "safe-upgrade driver must source deadline.sh"

start="$(now_ms)"
out="$(run_op_with_deadline 2 sh -c 'printf fast')"
elapsed=$(( $(now_ms) - start ))
[ "$out" = "fast" ] || fail "fast command output changed: $out"
[ "$elapsed" -lt 1000 ] \
  || fail "fast command waited for its two-second deadline (${elapsed}ms)"

start="$(now_ms)"
rc=0
run_op_with_deadline 1 sleep 5 || rc=$?
elapsed=$(( $(now_ms) - start ))
[ "$rc" -eq 124 ] || fail "slow command returned $rc, expected 124"
[ "$elapsed" -ge 800 ] && [ "$elapsed" -lt 3000 ] \
  || fail "one-second deadline returned outside its bound (${elapsed}ms)"

echo "PASS last-stack-lastdb-safe-upgrade-deadline"
