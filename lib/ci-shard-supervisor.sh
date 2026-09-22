#!/usr/bin/env bash
# shellcheck shell=bash
# Supervise the background test shards of .lastgit/ci.sh.
#
# Two defects, one cause. Each shard writes to its own log file, and the parent
# printed those files only after EVERY shard exited. On 2026-09-22 Forge killed
# last-stack run 272 (PR 108) at its 25-minute timeout-minutes. A runner kill is
# SIGKILL, so no trap ran and nothing was printed: the job log ended at
# "test scripts use 4 bounded shards" and then "signal: killed". The red status
# read as a test failure, and nobody could say which test was slow. The same
# silence hit a local run under `gtimeout 1500s` (exit 124, no shard output).
#
# This supervisor fixes both:
#   1. A heartbeat. Every PROGRESS seconds it prints one line per shard: the
#      test the shard is running now and how many tests it finished. A kill at
#      any moment leaves the last heartbeat in the job log.
#   2. An internal deadline below the runner's own. When the budget runs out it
#      prints CI_DEADLINE_EXCEEDED with the running test of each live shard,
#      stops the shards, and sets CI_SUPERVISE_TIMED_OUT=1 so the caller exits
#      124 (a timeout) and not 1 (a test failure).
#
# papercut-last-stack-ci-deadline-kill-reports-as-test-failure-with-no-shard-output-20260922
# Bash 3.2 compatible: no `wait -n`, no associative arrays.

# The test a shard is running now: its last "ci_test start:" line.
ci_shard_current_test() {  # log
  local line
  line="$(grep '^ci_test start: ' "$1" 2>/dev/null | tail -n 1 || true)"
  printf '%s' "${line#ci_test start: }"
}

# How many tests a shard finished (pass or fail).
ci_shard_done_count() {  # log
  local n
  n="$(grep -c '^ci_test done: ' "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Stop one shard and everything under it. ci.sh starts each shard in its own
# process group (set -m), so the negative pid reaches the test the shard runs
# and that test's children. The plain pid is the fallback when the shard does
# not lead a group (a caller without job control).
ci_shard_stop() {  # pid
  local pid="$1"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "${CI_SUPERVISE_KILL_GRACE_SECS:-5}" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

# ci_supervise_shards LOG_DIR PROGRESS_SECS DEADLINE_SECS PID...
#   LOG_DIR/<index>.log is the log of the shard at position <index>.
#   PROGRESS_SECS 0 disables the heartbeat; DEADLINE_SECS 0 disables the budget.
# Returns when every shard exited or the deadline fired. The caller still runs
# `wait` on each pid to collect exit codes.
ci_supervise_shards() {
  local log_dir="$1" progress="$2" deadline="$3"
  shift 3
  local start="$SECONDS" next_beat alive elapsed index pid
  next_beat=$((SECONDS + progress))
  CI_SUPERVISE_TIMED_OUT=0
  CI_SUPERVISE_RUNNING_AT_DEADLINE=""
  while :; do
    alive=0
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then alive=$((alive + 1)); fi
    done
    [ "$alive" -gt 0 ] || return 0
    elapsed=$((SECONDS - start))

    if [ "$deadline" -gt 0 ] && [ "$elapsed" -ge "$deadline" ]; then
      CI_SUPERVISE_TIMED_OUT=1
      echo "CI_DEADLINE_EXCEEDED elapsed=${elapsed}s budget=${deadline}s running=${alive}/$#: this is a timeout, not a test failure"
      index=0
      for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
          echo "  shard ${index} still running: $(ci_shard_current_test "$log_dir/$index.log") (finished $(ci_shard_done_count "$log_dir/$index.log") tests)"
          CI_SUPERVISE_RUNNING_AT_DEADLINE="${CI_SUPERVISE_RUNNING_AT_DEADLINE} ${index}"
        fi
        index=$((index + 1))
      done
      for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then ci_shard_stop "$pid"; fi
      done
      return 0
    fi

    if [ "$progress" -gt 0 ] && [ "$SECONDS" -ge "$next_beat" ]; then
      echo "ci_progress elapsed=${elapsed}s running=${alive}/$#"
      index=0
      for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
          echo "  shard ${index}: running $(ci_shard_current_test "$log_dir/$index.log") (finished $(ci_shard_done_count "$log_dir/$index.log"))"
        else
          echo "  shard ${index}: exited (finished $(ci_shard_done_count "$log_dir/$index.log"))"
        fi
        index=$((index + 1))
      done
      next_beat=$((SECONDS + progress))
    fi
    sleep "${CI_SUPERVISE_POLL_SECS:-2}"
  done
}
