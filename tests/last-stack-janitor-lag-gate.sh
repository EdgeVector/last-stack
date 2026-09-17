#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-janitor-lag-gate"
chmod +x "$GATE"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/janitor-lag-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/last-stack/bin" "$tmp/locks" "$tmp/success" "$tmp/state"
cat >"$tmp/last-stack/bin/last-stack-brain-append-heartbeat" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/last-stack/bin/last-stack-brain-append-heartbeat" "$GATE"

export LAST_STACK_ROOT="$tmp/last-stack"
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
export LAST_STACK_JANITOR_LAG_STATE="$tmp/state/state.json"
export LAST_STACK_JANITOR_LAG_LOCKS_DIR="$tmp/locks"
export LAST_STACK_JANITOR_LAG_SUCCESS_DIR="$tmp/success"
export LAST_STACK_JANITOR_LAG_NOW_EPOCH=1700000000
export LAST_STACK_JANITOR_LAG_STALE_SEC=7200
export LAST_STACK_JANITOR_LAG_CADENCE_SEC=3600
export ROUTINE_ID=dead-code-reaper
unset ROUTINES_POSTURE || true

# Fresh mtime: touch the file at now.
write_state() {
  cat >"$tmp/state/state.json"
  # Make mtime match NOW so the file is not stale. `touch -t` needs local time;
  # set mtime via python so the test is timezone-stable.
  LAST_STACK_JANITOR_LAG_NOW_EPOCH="$LAST_STACK_JANITOR_LAG_NOW_EPOCH" \
  STATE_PATH="$tmp/state/state.json" python3 -c '
import os, time
p = os.environ["STATE_PATH"]
now = int(os.environ["LAST_STACK_JANITOR_LAG_NOW_EPOCH"])
os.utime(p, (now, now))
'
}

run_case() {
  local name="$1"
  local expected_rc="$2"
  local expected_text="$3"
  set +e
  out="$("$GATE" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "$name: expected rc=$expected_rc, got rc=$rc" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q "$expected_text"; then
    echo "$name: missing $expected_text" >&2
    echo "$out" >&2
    exit 1
  fi
}

# Burst after epoch 0, idle, doing=0 → proceed once
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": 4, "ships_24h": 20, "doing": 0},
    {"ts": "2023-11-14T22:00:00Z", "ships_last_h": 0, "ships_24h": 20, "doing": 0}
  ]
}
JSON
run_case burst-debt 10 'last_ship_ts=2023-11-14T20:00:00Z'

# Consume is runRoutine's job. A success stamp after the burst skips.
# 20:00:00Z ship is epoch 1699992000. Stamp after that point consumes the burst.
printf '%s\n' '1699993000' >"$tmp/success/dead-code-reaper.success-epoch"
run_case consumed 0 'no-lag-debt'

# Cadence floor: success just now, even with later ships, skips
printf '%s\n' '1699999000' >"$tmp/success/dead-code-reaper.success-epoch"
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T22:13:00Z", "ships_last_h": 1, "ships_24h": 20, "doing": 0}
  ]
}
JSON
run_case cadence-floor 0 'cadence-floor'
rm -f "$tmp/success/dead-code-reaper.success-epoch"

# Starve floor N=1
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T22:00:00Z", "ships_last_h": 0, "ships_24h": 0, "doing": 0}
  ]
}
JSON
run_case starve 0 'starve ships_24h=0'

# Null ships_last_h is not debt
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": null, "ships_24h": 20, "doing": 0}
  ]
}
JSON
run_case null-ships-last-h 0 'no-lag-debt'

# doing>0 skips
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": 2, "ships_24h": 20, "doing": 1}
  ]
}
JSON
run_case doing 0 'doing=1'

# Pickup lock with a live pid skips
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": 2, "ships_24h": 20, "doing": 0}
  ]
}
JSON
printf '{"pid":%s,"ownerPid":%s,"harnessPid":%s}\n' "$$" "$$" "$$" \
  >"$tmp/locks/last-stack-fkanban-pickup.lock"
run_case pickup-lock 0 'pickup-in-flight'
rm -f "$tmp/locks/last-stack-fkanban-pickup.lock"

# bak lock is ignored; dead pid is not in flight
printf '{"pid":999999999}\n' >"$tmp/locks/last-stack-fkanban-pickup.lock.bak-old"
printf '999999999\n' >"$tmp/locks/last-stack-fkanban-pickup-w2.lock"
run_case dead-lock 10 'JANITOR_LAG_GATE proceed'
rm -f "$tmp/locks"/*

# Missing state skips
rm -f "$tmp/state/state.json"
run_case missing-state 0 'state-missing'

# Stale state skips
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": 2, "ships_24h": 20, "doing": 0}
  ]
}
JSON
STATE_PATH="$tmp/state/state.json" python3 -c '
import os
os.utime(os.environ["STATE_PATH"], (1000, 1000))
'
run_case stale-state 0 'state-stale'

# Last-tank defense skip
write_state <<'JSON'
{
  "history": [
    {"ts": "2023-11-14T20:00:00Z", "ships_last_h": 2, "ships_24h": 20, "doing": 0}
  ]
}
JSON
export ROUTINES_POSTURE=last-tank
run_case last-tank 0 'posture-last-tank'
unset ROUTINES_POSTURE

# Gate must not write success-epoch
[ ! -f "$tmp/success/dead-code-reaper.success-epoch" ] \
  || { echo "gate wrote success-epoch" >&2; exit 1; }

echo "ok last-stack-janitor-lag-gate"
