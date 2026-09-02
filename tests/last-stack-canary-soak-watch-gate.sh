#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-canary-soak-watch-gate"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-v2-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

boot_rows='{"boots":[{"pid":701,"process_start_ts":1788220800,"build":"vcanary","restart_cause":"initial"}]}'

run_gate() {
  LAST_STACK_CANARY_PIPELINE_DIR="$tmp/$1" \
  LAST_STACK_CANARY_V2_CANDIDATE=vcanary \
  LAST_STACK_CANARY_V2_BOOT_LEDGER_CMD="printf '%s\\n' '$boot_rows'" \
  LAST_STACK_CANARY_V2_STATUS_CHECK_CMD="${2:-true}" \
  LAST_STACK_CANARY_V2_HOST_CHECK_CMD="${3:-true}" \
  LAST_STACK_CANARY_V2_WINDOW_SECONDS=0 \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:00:00Z' \
  ROUTINES_RUN_DIR="$tmp/run-$1" \
    "$GATE"
}

green_out="$(run_gate green)"
printf '%s\n' "$green_out" | grep -q 'CANARY_V2_GATE candidate=vcanary verdict=green subject=none action=promote-eligible'
printf '%s\n' "$green_out" | grep -q 'ROUTINE_RESULT outcome=ok detail=verdict=green'
test -s "$tmp/run-green/canary-v2-gate.out"

# Green output stays held. A configured action cannot run until the separate
# execute switch is explicit.
action_log="$tmp/held-action"
held_out="$(LAST_STACK_CANARY_V2_ACTION_CMD="touch '$action_log'" run_gate held)"
printf '%s\n' "$held_out" | grep -q 'verdict=green subject=none action=promote-eligible'
test ! -e "$action_log"

# A second hourly run appends new observations, but it cannot duplicate the
# immutable boot row or introduce a wait marker.
second_out="$(run_gate green)"
printf '%s\n' "$second_out" | grep -q 'verdict=green'
test "$(jq -r 'select(.record_type == "boot") | .pid' "$tmp/green/ledger.jsonl" | wc -l | tr -d ' ')" -eq 1
if grep -Eq 'SOAK_WAIT|active_execution|resume_key' "$tmp/green/ledger.jsonl"; then
  echo 'the v2 gate wrote a legacy wait marker' >&2
  exit 1
fi

set +e
status_red="$(run_gate status-red 'exit 7')"
status_red_rc=$?
set -e
test "$status_red_rc" -eq 0
printf '%s\n' "$status_red" | grep -q 'verdict=red subject=build action=heal'
printf '%s\n' "$status_red" | grep -q 'ROUTINE_RESULT outcome=error detail=verdict=red'

set +e
host_pause="$(run_gate host-pause true 'exit 9')"
host_pause_rc=$?
set -e
test "$host_pause_rc" -eq 0
printf '%s\n' "$host_pause" | grep -q 'verdict=window-open subject=host action=pause-window'
printf '%s\n' "$host_pause" | grep -q 'ROUTINE_RESULT outcome=noop detail=verdict=window-open'

set +e
missing_boot="$(LAST_STACK_CANARY_PIPELINE_DIR="$tmp/missing-boot" \
  LAST_STACK_CANARY_V2_CANDIDATE=vcanary \
  LAST_STACK_CANARY_V2_BOOT_LEDGER_CMD='exit 28' \
  LAST_STACK_CANARY_V2_STATUS_CHECK_CMD=true \
  LAST_STACK_CANARY_V2_HOST_CHECK_CMD=true \
  LAST_STACK_CANARY_V2_WINDOW_SECONDS=0 \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:00:00Z' \
  "$GATE")"
missing_boot_rc=$?
set -e
test "$missing_boot_rc" -eq 0
printf '%s\n' "$missing_boot" | grep -q 'verdict=red subject=build action=heal'
printf '%s\n' "$missing_boot" | grep -q 'sync=failed'

# The source itself must never drive a Loom graph or write a wait/resume marker.
if rg -n 'SOAK_WAIT|last-stack-canary-loom|last-stack-canary-red-loom|resume_key|active_execution' \
  "$GATE"; then
  echo 'the v2 gate still contains legacy Loom state' >&2
  exit 1
fi
if rg -n 'SOAK_WAIT|last-stack-canary-loom|last-stack-canary-red-loom|resume_key|active_execution' \
  "$ROOT/routines/lastdb-canary-soak-watch.md"; then
  echo 'the v2 routine still contains legacy Loom state' >&2
  exit 1
fi

echo "ok last-stack-canary-soak-watch-gate"
