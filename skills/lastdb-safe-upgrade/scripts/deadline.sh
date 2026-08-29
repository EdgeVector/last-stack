#!/usr/bin/env bash
# Deadline helper for safe-upgrade probes. Safe to source in unit tests.

run_op_with_deadline() {
  # $1 = seconds; rest = command. Returns 124 if the deadline killed it.
  # Use one timer process. A shell wrapper around `sleep` leaves the sleep
  # orphaned when the wrapper is killed, and that orphan keeps command-
  # substitution capture pipes open until the full deadline expires.
  local secs="$1"; shift
  "$@" &
  local pid=$!
  perl -e '
    my ($secs, $target) = @ARGV;
    select(undef, undef, undef, $secs);
    kill 9, $target;
  ' "$secs" "$pid" </dev/null >/dev/null 2>&1 &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  [ "$rc" -eq 137 ] && return 124
  return "$rc"
}
