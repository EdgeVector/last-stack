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

# --- host lock: one last-stack gate runs its shards at a time ----------------
# Measured 2026-09-22 on the macos-arm64 runner (capacity 2): a gate alone ran
# in 10-15 minutes (runs 283-286); two gates side by side both hit the 25-minute
# kill (runs 272/273, 287/288). Eight test streams on a host at load ~100 thrash
# each other, so the pair finishes later than the two runs back to back. The
# lock makes the second gate WAIT (with a heartbeat) instead of competing.
# Opt-in: the Forge workflow sets LAST_STACK_CI_HOST_LOCK=1. A local run does
# not take it unless asked.
#
# Stale holders: Forge ends a timed-out job with SIGKILL, so no trap removes the
# lock. A holder whose pid is gone, or a lock older than the max age, is taken
# over. A waiter that runs out of patience proceeds WITHOUT the lock and says so,
# because a late gate is better than a gate that never runs.
CI_HOST_LOCK_HELD=""

ci_host_lock_acquire() {  # lock-dir wait-secs max-age-secs progress-secs
  local dir="$1" wait="$2" max_age="$3" progress="$4"
  local start="$SECONDS" next_beat holder age now mtime
  next_beat=$((SECONDS + progress))
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$dir/pid"
      printf '%s\n' "${GITHUB_REPOSITORY:-local} run=${GITHUB_RUN_NUMBER:-?} sha=${GITHUB_SHA:-?}" >"$dir/owner"
      CI_HOST_LOCK_HELD="$dir"
      echo "ci_host_lock acquired after $((SECONDS - start))s: $dir"
      return 0
    fi
    holder="$(cat "$dir/pid" 2>/dev/null || true)"
    now="$(date +%s)"
    mtime="$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo "$now")"
    age=$((now - mtime))
    if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } || [ "$age" -ge "$max_age" ]; then
      echo "ci_host_lock stale (holder pid=${holder:-none} age=${age}s); taking it over"
      rm -rf -- "$dir"
      continue
    fi
    if [ "$((SECONDS - start))" -ge "$wait" ]; then
      echo "ci_host_lock NOT acquired after ${wait}s (holder: $(cat "$dir/owner" 2>/dev/null || echo unknown)); running without it"
      return 0
    fi
    if [ "$progress" -gt 0 ] && [ "$SECONDS" -ge "$next_beat" ]; then
      echo "ci_host_lock waiting $((SECONDS - start))s for a sibling gate: $(cat "$dir/owner" 2>/dev/null || echo unknown)"
      next_beat=$((SECONDS + progress))
    fi
    sleep "${CI_SUPERVISE_POLL_SECS:-2}"
  done
}

ci_host_lock_release() {
  [ -n "$CI_HOST_LOCK_HELD" ] || return 0
  if [ "$(cat "$CI_HOST_LOCK_HELD/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf -- "$CI_HOST_LOCK_HELD"
  fi
  CI_HOST_LOCK_HELD=""
}
