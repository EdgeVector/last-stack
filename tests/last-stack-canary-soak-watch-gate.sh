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
  hang)
    # Ignore SIGTERM, so only the -k SIGKILL escalation can stop this. That is
    # the case the plain routines cap could not handle: it TERMed the gate and
    # left the launcher's descendants alive, still writing into a finished run.
    trap '' TERM
    printf '%s\n' 'starting'
    sleep 60
    ;;
esac
SH

chmod 755 "$launcher"

run_gate() {
  TEST_CALLS="$calls" \
  TEST_LAUNCHER_MODE="$1" \
  ROUTINES_RUN_DIR="$tmp/run-$1" \
  LAST_STACK_CANARY_SOAK_GATE_LAUNCHER="$launcher" \
  LAST_STACK_CANARY_SOAK_GATE_TIMEOUT_SEC="${GATE_TIMEOUT_SEC:-780}" \
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

# A launcher that never returns must be bounded BY THE GATE, reported, and
# reaped. Before this the routines cap SIGTERMed the whole gate: no trailer, no
# evidence, `gate-timeout` with 0-byte logs, and live descendants.
if command -v timeout >/dev/null 2>&1; then
  : >"$calls"
  set +e
  start="$(date -u +%s)"
  hang_out="$(GATE_TIMEOUT_SEC=2 run_gate hang)"
  hang_rc=$?
  elapsed=$(( $(date -u +%s) - start ))
  set -e

  # Exit 0 with a terminal result — routinesd reads the outcome from the
  # trailer instead of recording a kill.
  test "$hang_rc" -eq 0
  printf '%s\n' "$hang_out" | grep -q 'CANARY_SOAK_GATE_LAUNCHER_TIMEOUT after=2s'
  printf '%s\n' "$hang_out" | grep -q 'ROUTINE_RESULT outcome=error detail=launcher-timeout=2s'

  # Not handed to the full agent: that would re-run the same unbounded call.
  if printf '%s\n' "$hang_out" | grep -q 'CANARY_SOAK_GATE_PROCEED'; then
    echo "hang handed off to the agent instead of reporting" >&2
    exit 1
  fi

  # The evidence the timeout path used to lose entirely.
  test -s "$tmp/run-hang/canary-soak-gate.out"
  grep -q 'starting' "$tmp/run-hang/canary-soak-gate.out"

  # Bounded by the gate, not by anything outside it. The stub sleeps 60s.
  test "$elapsed" -lt 30

  # A bad value must fall back to the default, never to "no bound".
  : >"$calls"
  set +e
  bad_out="$(GATE_TIMEOUT_SEC=nonsense timeout -k 2s 20s env \
    TEST_CALLS="$calls" TEST_LAUNCHER_MODE=idle ROUTINES_RUN_DIR="$tmp/run-bad" \
    LAST_STACK_CANARY_SOAK_GATE_LAUNCHER="$launcher" \
    LAST_STACK_CANARY_SOAK_GATE_TIMEOUT_SEC=nonsense "$GATE")"
  bad_rc=$?
  set -e
  test "$bad_rc" -eq 0
  printf '%s\n' "$bad_out" | grep -q 'outcome=noop detail=no-key'
else
  echo "note: coreutils timeout unavailable, skipped the hang bound test" >&2
fi

echo "ok last-stack-canary-soak-watch-gate"
