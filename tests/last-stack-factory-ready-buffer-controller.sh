#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CONTROLLER="$ROOT/bin/last-stack-factory-ready-buffer-controller"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/kanban" <<'EOF'
#!/bin/sh
set -eu
[ "${FAIL_BOARD:-0}" -eq 0 ] || exit 41
if [ "${1:-}" = pickup ] && [ "${2:-}" = claim-v2 ] && [ -n "${FAKE_CLAIM:-}" ]; then
  printf '%s\n' "$FAKE_CLAIM"
  exit 0
fi
printf '{"ready":%s}\n' "${FAKE_READY:-0}"
EOF

cat > "$TMP/bin/routines" <<'EOF'
#!/bin/sh
set -eu
printf 'cap=%s trigger=%s args=%s\n' \
  "${MILESTONE_DRIVER_SAFETY_CAP:-}" \
  "${MILESTONE_DRIVER_TRIGGER:-}" \
  "$*" >> "$ROUTINES_LOG"
EOF

chmod +x "$TMP/bin/kanban" "$TMP/bin/routines"

run_controller() {
  ready="$1"
  state_file="$2"
  now_epoch="$3"
  FAKE_READY="$ready" \
  ROUTINES_LOG="$TMP/routines.log" \
  LAST_STACK_READY_BUFFER_BOARD_CLI="$TMP/bin/kanban" \
  LAST_STACK_READY_BUFFER_ROUTINES_CLI="$TMP/bin/routines" \
  LAST_STACK_READY_BUFFER_STATE_FILE="$state_file" \
  LAST_STACK_READY_BUFFER_NOW_EPOCH="$now_epoch" \
    "$CONTROLLER" --json
}

: > "$TMP/routines.log"

out="$(run_controller 0 "$TMP/state/zero" 1000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]

out="$(run_controller 2 "$TMP/state/two" 1000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]

out="$(run_controller 3 "$TMP/state/three" 1000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = none ]

out="$(run_controller 6 "$TMP/state/six" 1000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = none ]

[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -eq 4 ]
[ "$(grep -c 'cap=1 trigger=ready-buffer-controller args=run last-stack-milestone-driver --quiet' "$TMP/routines.log")" -eq 2 ]

if FAIL_BOARD=1 \
  ROUTINES_LOG="$TMP/routines.log" \
  LAST_STACK_READY_BUFFER_BOARD_CLI="$TMP/bin/kanban" \
  LAST_STACK_READY_BUFFER_ROUTINES_CLI="$TMP/bin/routines" \
  LAST_STACK_READY_BUFFER_STATE_FILE="$TMP/state/unreadable" \
    "$CONTROLLER" --json > "$TMP/unreadable.json"; then
  echo "FAIL: unreadable board data must fail closed" >&2
  exit 1
fi
[ "$(jq -r .detail "$TMP/unreadable.json")" = board-unreadable ]
[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -eq 4 ]

out="$(run_controller 0 "$TMP/state/cooldown" 2000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]
out="$(run_controller 0 "$TMP/state/cooldown" 2001)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = cooldown ]
[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -eq 6 ]

live_state="$TMP/state/live-lock"
mkdir -p "$live_state.lock"
printf '%s\n' "$$" >"$live_state.lock/pid"
printf '%s\n' 1000 >"$live_state.lock/started"
out="$(run_controller 0 "$live_state" 5000)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = controller-busy ]
[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -eq 6 ]

stale_state="$TMP/state/stale-lock"
mkdir -p "$stale_state.lock"
printf '%s\n' 99999999 >"$stale_state.lock/pid"
printf '%s\n' 1000 >"$stale_state.lock/started"
out="$(run_controller 0 "$stale_state" 5000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]
[ "$(printf '%s\n' "$out" | jq -r .lock_reclaimed)" = true ]
[ ! -e "$stale_state.lock" ]
[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -eq 8 ]

out="$(run_controller 3 "$TMP/state/no-lock-recovery" 5000)"
[ "$(printf '%s\n' "$out" | jq -r .lock_reclaimed)" = false ]
[ "$(printf '%s\n' "$out" | jq -r .north_star_driver)" = null ]

# The North Star driver always gets an early chance alongside the milestone
# driver now — decision-2026-09-27-portfolio-admission-allow-all removed the
# admitted-portfolio drain signal this used to gate on.
: > "$TMP/routines.log"
out="$(run_controller 0 "$TMP/state/ns-runs" 5000)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]
[ "$(printf '%s\n' "$out" | jq -r .north_star_driver)" = ran ]
[ "$(grep -c 'args=run last-stack-north-star-driver --quiet' "$TMP/routines.log")" -eq 1 ]

# Cooldown still gates both drivers together.
out="$(run_controller 0 "$TMP/state/ns-runs" 5001)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = cooldown ]
[ "$(grep -c 'args=run last-stack-north-star-driver --quiet' "$TMP/routines.log")" -eq 1 ]

# Ready cards that all overlap a doing card's surfaces are not supply.
overlap='{"result":"none","dry_run":true,"scanned":2,"skipped":[{"slug":"a","reason":"surface overlap with doing card x"},{"slug":"b","reason":"surface overlap with doing card y"}]}'
before="$(wc -l < "$TMP/routines.log" | tr -d ' ')"
out="$(FAKE_CLAIM="$overlap" run_controller 4 "$TMP/state/overlap" 9000 2>/dev/null)"
[ "$(printf '%s\n' "$out" | jq -r .action)" = run ]
[ "$(printf '%s\n' "$out" | jq -r .ready)" = 0 ]
[ "$(wc -l < "$TMP/routines.log" | tr -d ' ')" -gt "$before" ]

# A claimable card, a mixed skip list, or an unreadable probe keeps the count.
claimed='{"result":"claimed","dry_run":true,"card":{"slug":"a"}}'
out="$(FAKE_CLAIM="$claimed" run_controller 4 "$TMP/state/claimable" 9000)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = threshold-satisfied ]
mixed='{"result":"none","scanned":2,"skipped":[{"slug":"a","reason":"surface overlap with doing card x"},{"slug":"b","reason":"lane cap"}]}'
out="$(FAKE_CLAIM="$mixed" run_controller 4 "$TMP/state/mixed" 9000)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = threshold-satisfied ]
out="$(FAKE_CLAIM='not json' run_controller 4 "$TMP/state/garbled" 9000)"
[ "$(printf '%s\n' "$out" | jq -r .detail)" = threshold-satisfied ]

grep -q 'MILESTONE_DRIVER_SAFETY_CAP:-8' "$ROOT/routines/milestone-driver.md"
grep -q 'ready-buffer controller sets this value to 1' "$ROOT/routines/milestone-driver.md"
grep -q 'Create at most \*\*one `Kind: pr` card\*\* per run.' "$ROOT/routines/milestone-driver.md"

echo "ok: ready-buffer controller"
