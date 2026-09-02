#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-canary-v2-dogfood-gate"
PIPELINE="$ROOT/bin/last-stack-canary-pipeline"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-v2-dogfood.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

dogfood="$tmp/dogfood"
calls="$tmp/calls"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >>"${DOGFOOD_CALLS:?}"' \
  'case " $* " in' \
  '  *" --dry-run "*) printf "%s\\n" "{\\"version\\":\\"vnext\\",\\"state\\":\\"dogfood_green\\"}" ;;' \
  '  *" --cutover "*) printf "%s\\n" "{\\"safe_upgrade\\":\\"loom-cutover-green\\",\\"state\\":\\"dogfood_green\\"}" ;;' \
  '  *) exit 2 ;;' \
  'esac' >"$dogfood"
chmod 755 "$dogfood"

run_gate() {
  DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="printf '%s\\n' 'pid=800 process_start_ts=1 build=vcurrent'" \
    "$GATE"
}

: >"$calls"
allow_out="$(run_gate)"
printf '%s\n' "$allow_out" | grep -q 'CANARY_V2_DOGFOOD result=ok candidate=vnext cutover=loom-cutover-green'
printf '%s\n' "$allow_out" | grep -q 'ROUTINE_RESULT outcome=ok detail=cutover=loom-cutover-green candidate=vnext'
test "$(wc -l <"$calls" | tr -d ' ')" -eq 2
grep -q -- '--cutover --json' "$calls"

# A current canary near the quiet-window end holds a normal newer cutover.
hold_dir="$tmp/hold"
"$PIPELINE" --state-dir "$hold_dir" record-boot --candidate vcurrent --pid 801 \
  --start-ts '2026-09-02T00:00:00Z' --build vcurrent >/dev/null
"$PIPELINE" --state-dir "$hold_dir" reconcile --candidate vcurrent \
  --window-seconds 86400 --at '2026-09-02T00:30:00Z' >/dev/null
: >"$calls"
hold_out="$(DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$hold_dir" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="printf '%s\\n' 'pid=801 process_start_ts=1 build=vcurrent'" \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:30:00Z' \
  LAST_STACK_CANARY_V2_CUTOVER_HOLD_HOURS=24 \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  "$GATE")"
printf '%s\n' "$hold_out" | grep -q 'result=noop candidate=vnext primary=vcurrent evidence=quiet_window_near_complete'
printf '%s\n' "$hold_out" | grep -q 'ROUTINE_RESULT outcome=noop detail=cutover_hold=quiet_window_near_complete'
test "$(wc -l <"$calls" | tr -d ' ')" -eq 1
grep -q -- '--dry-run --json' "$calls"

# An absent primary identity stops the line and writes durable observer evidence.
: >"$calls"
missing_out="$(DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$tmp/missing-identity" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD='exit 9' \
  "$GATE")"
printf '%s\n' "$missing_out" | grep -q 'result=error subject=observer evidence=primary_identity_absent'
"$PIPELINE" --state-dir "$tmp/missing-identity" --json line-status \
  | jq -e '.state == "line-stopped" and .subject == "observer"' >/dev/null
test ! -s "$calls"

if rg -n 'lastdb-canary-release|SOAK_WAIT|last-stack-canary-loom' "$GATE"; then
  echo 'the v2 dogfood gate starts the retired release graph' >&2
  exit 1
fi
grep -q 'last-stack-canary-v2-dogfood-gate' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'status = "paused"' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"

echo "ok last-stack-canary-v2-dogfood-gate"
