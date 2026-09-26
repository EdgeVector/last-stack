#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-disk-reclaim-gate"
chmod +x "$GATE"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/disk-reclaim-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/last-stack/bin"
cat >"$tmp/last-stack/bin/last-stack-brain-append-heartbeat" <<SH
#!/usr/bin/env bash
# Record what the gate asked to heartbeat, so a test can assert on it.
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --line) printf '%s\n' "\$2" >>"$tmp/heartbeat-lines.log"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
SH
chmod +x "$tmp/last-stack/bin/last-stack-brain-append-heartbeat" "$GATE"

export LAST_STACK_ROOT="$tmp/last-stack"
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=80

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

# 200 GiB free (200 * 1024 * 1024 KiB) ≥ 80 → skip
export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 209715200 1% /'"
run_case above-floor 0 'above-floor'

# 10 GiB free < 80 → proceed
export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 10485760 1% /'"
run_case under-floor 10 'under-floor'

export LAST_STACK_DISK_RECLAIM_DF_CMD="false"
run_case df-failed 10 'df-failed'

export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'not a df table'"
run_case df-parse-failed 10 'df-parse-failed'

# ---------------------------------------------------------------------------
# Mechanical Loom step-worktree retention runs on the SKIP path.
#
# Before 2026-09-26 the sweep lived only inside the harness, which the floor
# skips, so it never ran on a healthy host and ~/.loom/worktrees grew without
# a bound. The gate now runs it when it declines to dispatch.
# ---------------------------------------------------------------------------

above_floor() {
  export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 209715200 1% /'"
}
under_floor() {
  export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 10485760 1% /'"
}

sweep_marker="$tmp/sweep-ran"
mk_sweep() {
  # $1: exit code, $2: stdout body
  rm -f "$sweep_marker"
  cat >"$tmp/loom-wt-reclaim" <<SH
#!/usr/bin/env bash
: >"$sweep_marker"
printf '%s\n' "$2"
exit $1
SH
  chmod +x "$tmp/loom-wt-reclaim"
  export LAST_STACK_LOOM_WT_RECLAIM_BIN="$tmp/loom-wt-reclaim"
}

# The helper is missing: the gate still skips cleanly and says so.
above_floor
unset LAST_STACK_LOOM_WT_RECLAIM_BIN || true
export LAST_STACK_LOOM_WT_RECLAIM_BIN="$tmp/does-not-exist"
run_case sweep-absent 0 'loom_wt=absent'

# The helper runs and its summary reaches the skip reason AND the heartbeat.
mk_sweep 0 'last-stack-loom-worktree-reclaim: reclaim status=failed age_h=49 x
loom_wt_seen=34 loom_wt_reclaimed=10 loom_wt_kept=24 loom_wt_liveness_unavailable=0 dry_run=0'
run_case sweep-ran 0 'loom_wt_reclaimed=10'
[ -f "$sweep_marker" ] || { echo "sweep-ran: helper was not invoked" >&2; exit 1; }
grep -q 'loom_wt_reclaimed=10' "$tmp/heartbeat-lines.log" 2>/dev/null \
  || { echo "sweep-ran: heartbeat line does not carry the receipt" >&2; cat "$tmp/heartbeat-lines.log" >&2 || true; exit 1; }

# A failing sweep is reported and still skips with rc=0.
mk_sweep 3 'boom'
run_case sweep-failed 0 'loom_wt=failed rc=3'

# A sweep that prints no summary line is reported, not guessed at.
mk_sweep 0 'nothing useful here'
run_case sweep-no-summary 0 'loom_wt=no-summary'

# Opt-out.
mk_sweep 0 'loom_wt_seen=1 loom_wt_reclaimed=1'
LAST_STACK_DISK_RECLAIM_GATE_LOOM_WT=0 run_case sweep-disabled 0 'loom_wt=disabled'
[ -f "$sweep_marker" ] && { echo "sweep-disabled: helper ran anyway" >&2; exit 1; }

# UNDER the floor the gate proceeds and must NOT run the sweep: the harness
# runs the same helper, and the gate must not delay an emergency dispatch.
mk_sweep 0 'loom_wt_seen=1 loom_wt_reclaimed=1'
under_floor
run_case sweep-not-on-proceed 10 'under-floor'
[ -f "$sweep_marker" ] && { echo "sweep-not-on-proceed: helper ran on the proceed path" >&2; exit 1; }

# The budget must bound WALL CLOCK, not just the direct child. A sweep whose
# grandchild outlives it still holds the write end of a capture pipe, so a
# `$(...)` capture blocks for the grandchild's full runtime while the bound
# reports success. Measured 30s against a 2s budget before this was fixed.
sweep_budget=1
sweep_slow_secs=25
# Ceiling derived from what the test configures: the budget, plus teardown
# slack that stays far below the fixture's own runtime. A bounded sweep lands
# near $sweep_budget; an unbounded one lands near $sweep_slow_secs.
budget_ceiling=$(( sweep_budget + (sweep_slow_secs / 5) ))

above_floor
cat >"$tmp/loom-wt-slow" <<SH
#!/usr/bin/env bash
: >"$sweep_marker"
( sleep $sweep_slow_secs ) &
sleep $sweep_slow_secs
SH
chmod +x "$tmp/loom-wt-slow"
export LAST_STACK_LOOM_WT_RECLAIM_BIN="$tmp/loom-wt-slow"
export LAST_STACK_DISK_RECLAIM_GATE_LOOM_WT_BUDGET_S="$sweep_budget"

budget_start="$(date +%s)"
run_case sweep-budget-enforced 0 'loom_wt=failed'
budget_elapsed=$(( $(date +%s) - budget_start ))
if [ "$budget_elapsed" -gt "$budget_ceiling" ]; then
  echo "sweep-budget-enforced: gate took ${budget_elapsed}s against a ${sweep_budget}s budget (ceiling ${budget_ceiling}s)" >&2
  exit 1
fi

# Run the same case again with gtimeout/timeout hidden, which is what a
# routinesd shell looks like: PATH=/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.
# resolves neither, so the perl arm is the one that runs in production. perl
# does NOT kill the process group, so this case is the only one that covers it.
budget_start="$(date +%s)"
set +e
out="$(PATH=/usr/bin:/bin "$GATE" 2>&1)"
rc=$?
set -e
budget_elapsed=$(( $(date +%s) - budget_start ))
if [ "$rc" -ne 0 ]; then
  echo "sweep-budget-enforced-no-gtimeout: expected rc=0, got rc=$rc" >&2
  echo "$out" >&2
  exit 1
fi
case "$out" in
  *loom_wt=failed*|*loom_wt=unbounded-skipped*) ;;
  *) echo "sweep-budget-enforced-no-gtimeout: missing a bounded-sweep token" >&2
     echo "$out" >&2; exit 1 ;;
esac
if [ "$budget_elapsed" -gt "$budget_ceiling" ]; then
  echo "sweep-budget-enforced-no-gtimeout: gate took ${budget_elapsed}s against a ${sweep_budget}s budget (ceiling ${budget_ceiling}s)" >&2
  exit 1
fi
unset LAST_STACK_DISK_RECLAIM_GATE_LOOM_WT_BUDGET_S

echo "ok last-stack-disk-reclaim-gate"
