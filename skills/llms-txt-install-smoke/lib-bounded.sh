#!/usr/bin/env bash
# Bounded-command helpers for the llms.txt install smoke.
#
# Three incomplete runs in ten days (papercut-llms-txt-install-smoke-times-out-45min)
# all stalled inside the "quick try" block: search init / brain concept new /
# brain get / brain ask / brain search have no bound, so one hung call ate the
# whole routine budget and the run produced no VERDICT line at all. Every
# quick-try call now goes through run_bounded so a hang degrades into a normal
# timed-out FAIL that still reaches the RED footer.
#
# A per-call bound alone is not enough. The 2026-08-29 recurrence stalled
# EARLIER than quick-try — inside `brain init`'s node-schema bootstrap — and the
# whole run was killed by the agent tool's hard 10-minute foreground cap with no
# VERDICT line at all. Per-call bounds cannot prevent that: N calls each under
# their own bound still sum past the cap. So the smoke also carries ONE global
# deadline (smoke_deadline_init) and clamps every bounded call to the time left
# under it (smoke_bounded_remaining). Once the budget is spent every remaining
# call gets the floor bound and fails fast, so the script always reaches its
# footer and prints a real VERDICT: RED instead of dying mute.
#
# Sourced by run.sh; exercised directly by
# tests/llms-txt-install-smoke-bounded.sh.

# Resolve a coreutils-style timeout binary once. Empty when the host has
# neither (stock macOS), which selects the pure-bash watchdog below.
smoke_timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then
    command -v gtimeout
  elif command -v timeout >/dev/null 2>&1; then
    command -v timeout
  fi
}

# Tests force the fallback path with SMOKE_TIMEOUT_BIN= (set but empty).
SMOKE_TIMEOUT_BIN="${SMOKE_TIMEOUT_BIN-$(smoke_timeout_bin)}"

# --- global deadline --------------------------------------------------------
#
# The floor a clamped bound is never reduced below. One second is enough for a
# call that is going to fail fast anyway, and keeps `run_bounded` from being
# handed a zero or negative bound once the budget is spent.
SMOKE_MIN_BOUND="${SMOKE_MIN_BOUND:-1}"

# smoke_deadline_init [total_seconds]
# Start the one global budget for this run. Called once, early, by run.sh.
# With no argument (or 0) the deadline is disabled and every clamp is a no-op,
# which is what an interactive `run.sh --keep` debugging session wants.
smoke_deadline_init() {
  SMOKE_STARTED_EPOCH="$(date +%s)"
  SMOKE_TOTAL_BUDGET="${1:-0}"
  export SMOKE_STARTED_EPOCH SMOKE_TOTAL_BUDGET
}

# smoke_elapsed
# Whole seconds since smoke_deadline_init. Zero before it is called, so a
# breadcrumb helper can use it unconditionally.
smoke_elapsed() {
  if [ -z "${SMOKE_STARTED_EPOCH:-}" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$(( $(date +%s) - SMOKE_STARTED_EPOCH ))"
}

# smoke_remaining
# Seconds left under the global deadline; 0 once spent. Prints a very large
# number when no deadline is armed, so callers can compare without special
# casing the disabled mode.
smoke_remaining() {
  if [ -z "${SMOKE_TOTAL_BUDGET:-}" ] || [ "${SMOKE_TOTAL_BUDGET:-0}" -le 0 ]; then
    printf '%s' 999999
    return 0
  fi
  local left=$(( SMOKE_TOTAL_BUDGET - $(smoke_elapsed) ))
  if [ "$left" -lt 0 ]; then
    left=0
  fi
  printf '%s' "$left"
}

# smoke_deadline_exceeded
# True (0) once the global budget is spent. Used for the breadcrumb that
# explains why the tail of the run is failing in one second each.
smoke_deadline_exceeded() {
  [ "$(smoke_remaining)" -le 0 ]
}

# smoke_bounded_remaining <requested_seconds>
# The bound to actually pass to run_bounded: the smaller of what the caller
# asked for and what is left of the global budget, never under SMOKE_MIN_BOUND.
# This is what keeps a sum of individually-bounded calls from overrunning the
# foreground cap.
smoke_bounded_remaining() {
  local requested="$1"
  local left
  left="$(smoke_remaining)"
  if [ "$left" -lt "$requested" ]; then
    requested="$left"
  fi
  if [ "$requested" -lt "$SMOKE_MIN_BOUND" ]; then
    requested="$SMOKE_MIN_BOUND"
  fi
  printf '%s' "$requested"
}

# run_bounded <seconds> <command> [args...]
# Returns 124 when the bound fired, otherwise the command's own exit status.
run_bounded() {
  local secs="$1"
  shift
  local rc=0

  if [ -n "${SMOKE_TIMEOUT_BIN:-}" ]; then
    "$SMOKE_TIMEOUT_BIN" -k 5 "$secs" "$@" || rc=$?
    # -k escalates to SIGKILL after the grace window; report one timeout code.
    if [ "$rc" -eq 137 ]; then
      rc=124
    fi
    return "$rc"
  fi

  # Pure-bash watchdog. The sentinel file distinguishes "the watchdog killed
  # it" from "the command died of its own signal", which a bare rc >= 128
  # check cannot do.
  local sentinel
  sentinel="$(mktemp "${TMPDIR:-/tmp}/llms-smoke-watchdog.XXXXXX")"
  rm -f "$sentinel"

  "$@" &
  local cmd_pid=$!
  (
    sleep "$secs"
    kill -0 "$cmd_pid" 2>/dev/null || exit 0
    : >"$sentinel"
    kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$cmd_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!

  wait "$cmd_pid" || rc=$?
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -e "$sentinel" ]; then
    rc=124
  fi
  rm -f "$sentinel"
  return "$rc"
}

# fail_steps_summary <fail entry> [...]
# Comma-joined leading step token of each recorded failure, deduped, so the
# visible RED verdict names the step instead of forcing a log dig.
fail_steps_summary() {
  local out=""
  local entry step
  for entry in "$@"; do
    step="${entry%% *}"
    [ -n "$step" ] || continue
    case ",$out," in
      *",$step,"*) continue ;;
    esac
    if [ -z "$out" ]; then
      out="$step"
    else
      out="$out,$step"
    fi
  done
  printf '%s' "$out"
}

# preserve_failure_log <source> <destination>
# Copy a RED run's detailed log out of the disposable sandbox before cleanup.
preserve_failure_log() {
  local source_log="$1"
  local destination_log="$2"

  [ -n "$destination_log" ] || return 1
  [ -f "$source_log" ] || return 1
  cp "$source_log" "$destination_log"
}
