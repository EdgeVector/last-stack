#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-canary-soak-watch-gate"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-soak-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

launcher="$tmp/launcher"
calls="$tmp/calls"

cat >"$launcher" <<'SH'
#!/usr/bin/env bash
printf 'launcher %s\n' "$*" >>"${TEST_CALLS:?}"
case "${TEST_LAUNCHER_MODE:-idle}" in
  idle)
    printf '%s\n' '{"outcome":"noop","detail":"no-key","status":"idle"}'
    printf '%s\n' 'ROUTINE_RESULT outcome=noop detail=no-key'
    ;;
  active)
    printf '%s\n' '{"outcome":"ok","detail":"soak-pending","status":"waiting"}'
    printf '%s\n' 'ROUTINE_RESULT outcome=ok detail=soak-pending'
    ;;
  failed)
    printf '%s\n' '{"outcome":"error","detail":"probe-red","status":"failed"}'
    printf '%s\n' 'ROUTINE_RESULT outcome=error detail=probe-red'
    exit 3
    ;;
  unreadable)
    printf '%s\n' '{"outcome":"error","detail":"loom-list-unreadable","status":"unavailable"}'
    printf '%s\n' 'ROUTINE_RESULT outcome=error detail=loom-list-unreadable'
    exit 3
    ;;
  malformed)
    printf '%s\n' 'not json'
    exit 3
    ;;
  empty-success)
    printf '%s\n' 'no result trailer'
    ;;
esac
SH

chmod 755 "$launcher"

run_gate() {
  TEST_CALLS="$calls" \
  TEST_LAUNCHER_MODE="$1" \
  ROUTINES_RUN_DIR="$tmp/run-$1" \
  LAST_STACK_CANARY_SOAK_GATE_LAUNCHER="$launcher" \
    "$GATE"
}

: >"$calls"
idle_out="$(run_gate idle)"
printf '%s\n' "$idle_out" | grep -q 'outcome=noop detail=no-key'
test "$(grep -c '^launcher ' "$calls")" -eq 1

: >"$calls"
active_out="$(run_gate active)"
printf '%s\n' "$active_out" | grep -q 'outcome=ok detail=soak-pending'

: >"$calls"
failed_out="$(run_gate failed)"
printf '%s\n' "$failed_out" | grep -q 'outcome=error detail=probe-red'
test -s "$tmp/run-failed/canary-soak-gate.out"

for mode in unreadable malformed empty-success; do
  : >"$calls"
  set +e
  out="$(run_gate "$mode")"
  rc=$?
  set -e
  test "$rc" -eq 10
  printf '%s\n' "$out" | grep -q 'CANARY_SOAK_GATE_PROCEED reason=tick-error'
  if printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT'; then
    echo "$mode emitted a terminal result before agent handoff" >&2
    exit 1
  fi
  test -s "$tmp/run-$mode/canary-soak-gate.out"
done

echo "ok last-stack-canary-soak-watch-gate"
