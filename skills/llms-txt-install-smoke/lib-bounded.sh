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
