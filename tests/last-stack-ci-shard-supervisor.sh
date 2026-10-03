#!/usr/bin/env bash
# Behaviour of lib/ci-shard-supervisor.sh, the heartbeat and internal deadline
# of the required gate's shard runner.
#
# A Forge timeout kill used to leave a job log with zero shard output, which
# read as a test failure
# (papercut-last-stack-ci-deadline-kill-reports-as-test-failure-with-no-shard-output-20260922).
# Pins that: a heartbeat names each shard's running test; the deadline names the
# stuck test, sets CI_SUPERVISE_TIMED_OUT, and stops the shard AND its child;
# fast shards finish with no timeout. Hermetic: fake shards, no network. ~8s.
#
# The heartbeat and the deadline are asserted in SEPARATE cases on purpose. A
# single case that wants both races them on a loaded host: see case 1b.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$ROOT/tests/ci/pid-is-live.sh"
# shellcheck source=../lib/ci-shard-supervisor.sh
. "$ROOT/lib/ci-shard-supervisor.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-supervisor.XXXXXX")"
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export CI_SUPERVISE_POLL_SECS=1
export CI_SUPERVISE_KILL_GRACE_SECS=2

# --- Case 1: one fast shard, one stuck shard -> deadline -------------------
logs="$TMP_ROOT/case1"
mkdir -p "$logs"
child_pid_file="$TMP_ROOT/stuck-child.pid"

set -m
bash -c 'echo "ci_test start: tests/fast.sh"; echo "ci_test done: tests/fast.sh rc=0 secs=0"' \
  </dev/null >"$logs/0.log" 2>&1 &
fast_pid=$!
bash -c 'echo "ci_test start: tests/ok.sh"; echo "ci_test done: tests/ok.sh rc=0 secs=0";
         echo "ci_test start: tests/stuck.sh"; sleep 300 & echo $! >"$1"; wait' _ "$child_pid_file" \
  </dev/null >"$logs/1.log" 2>&1 &
stuck_pid=$!
set +m

out="$TMP_ROOT/case1.out"
ci_supervise_shards "$logs" 1 3 "$fast_pid" "$stuck_pid" >"$out"

[ "$CI_SUPERVISE_TIMED_OUT" -eq 1 ] || fail "deadline did not set CI_SUPERVISE_TIMED_OUT"
grep -q '^CI_DEADLINE_EXCEEDED .*budget=3s.*a timeout, not a test failure' "$out" \
  || fail "deadline line missing or does not say timeout: $(cat "$out")"
grep -q 'shard 1 still running: tests/stuck.sh (finished 1 tests)' "$out" \
  || fail "deadline did not name the stuck test: $(cat "$out")"
if grep -q 'shard 0 still running' "$out"; then fail "a finished shard was reported as running"; fi
case "$CI_SUPERVISE_RUNNING_AT_DEADLINE" in *" 1"*) ;; *) fail "running-at-deadline list lacks shard 1" ;; esac
if pid_is_live "$stuck_pid"; then fail "stuck shard still alive after the deadline"; fi
child_pid="$(cat "$child_pid_file" 2>/dev/null || true)"
[ -n "$child_pid" ] || fail "fixture did not record its child pid"
if pid_is_live "$child_pid"; then
  kill -KILL "$child_pid" 2>/dev/null || true
  fail "the stuck shard's child survived; the stop must reach the process group"
fi
wait "$fast_pid" || fail "fast shard exit code lost"
if wait "$stuck_pid"; then fail "a stopped shard reported success"; fi

# --- Case 1b: the heartbeat, with no deadline to race -----------------------
# Regression 2026-09-26: case 1 asserted BOTH that the deadline fires and that a
# heartbeat was printed before it, with PROGRESS=1 and DEADLINE=3. Those two
# properties raced. The loop prints a heartbeat only on an iteration where
# SECONDS has advanced past next_beat AND elapsed is still under the budget, so
# one overrunning `sleep` in the first iteration skips straight to the deadline
# branch: last-stack#217 failed with "elapsed=4s budget=3s" and no ci_progress
# line at all, on a host running eight test streams. Widening the budget only
# buys a longer stall; the fix is to stop the deadline from being involved.
# DEADLINE=0 disables the budget, so the loop runs until the shard dies, and
# this case ends it from the outside the moment the heartbeat is in the file.
logs="$TMP_ROOT/case1b"
mkdir -p "$logs"
slow_child_pid_file="$TMP_ROOT/slow-child.pid"
set -m
bash -c 'echo "ci_test start: tests/ok.sh"; echo "ci_test done: tests/ok.sh rc=0 secs=0";
         echo "ci_test start: tests/slow.sh"; sleep 300 & echo $! >"$1"; wait' _ "$slow_child_pid_file" \
  </dev/null >"$logs/0.log" 2>&1 &
slow_pid=$!
set +m
out="$TMP_ROOT/case1b.out"
ci_supervise_shards "$logs" 1 0 "$slow_pid" >"$out" &
supervisor_pid=$!
# Wait for the LAST line of the heartbeat block, not its header: the header and
# the per-shard lines are separate `echo`s, so a poll that stops on
# `ci_progress` can read the file between the two and report a heartbeat that
# does not name its shard.
waited=0
until grep -q 'shard 0: running tests/slow.sh (finished 1)' "$out" 2>/dev/null; do
  waited=$((waited + 1))
  [ "$waited" -le 60 ] || { ci_shard_stop "$slow_pid"; fail "no heartbeat naming the running test in 60s: $(cat "$out")"; }
  sleep 1
done
grep -q '^ci_progress elapsed=' "$out" \
  || { ci_shard_stop "$slow_pid"; fail "no ci_progress header above the shard lines: $(cat "$out")"; }
grep -q '^ci_progress elapsed=[0-9]*s running=1/1$' "$out" \
  || { ci_shard_stop "$slow_pid"; fail "heartbeat header must count the live shards: $(cat "$out")"; }
if grep -q 'CI_DEADLINE_EXCEEDED' "$out"; then ci_shard_stop "$slow_pid"; fail "deadline 0 must disable the budget: $(cat "$out")"; fi
ci_shard_stop "$slow_pid"
wait "$supervisor_pid" || fail "the supervisor did not return once its only shard died"
slow_child_pid="$(cat "$slow_child_pid_file" 2>/dev/null || true)"
if [ -n "$slow_child_pid" ] && pid_is_live "$slow_child_pid"; then
  kill -KILL "$slow_child_pid" 2>/dev/null || true
  fail "the slow shard's child survived the outside stop"
fi
wait "$slow_pid" 2>/dev/null || true

# --- Case 2: every shard finishes -> no timeout ----------------------------
logs="$TMP_ROOT/case2"
mkdir -p "$logs"
set -m
bash -c 'echo "ci_test start: tests/a.sh"; echo "ci_test done: tests/a.sh rc=0 secs=0"' </dev/null >"$logs/0.log" 2>&1 &
a_pid=$!
bash -c 'echo "ci_test start: tests/b.sh"; sleep 1; echo "ci_test done: tests/b.sh rc=0 secs=1"' </dev/null >"$logs/1.log" 2>&1 &
b_pid=$!
set +m
out="$TMP_ROOT/case2.out"
ci_supervise_shards "$logs" 0 60 "$a_pid" "$b_pid" >"$out"
[ "$CI_SUPERVISE_TIMED_OUT" -eq 0 ] || fail "finished shards were reported as a timeout"
if grep -q 'CI_DEADLINE_EXCEEDED' "$out"; then fail "deadline fired for shards that finished"; fi
wait "$a_pid" && wait "$b_pid" || fail "finished shards lost their exit codes"

# --- Case 3: host lock -------------------------------------------------------
lock="$TMP_ROOT/state/ci-gate.lock"
out="$TMP_ROOT/lock.out"
ci_host_lock_acquire "$lock" 5 3600 0 >"$out"
[ "$CI_HOST_LOCK_HELD" = "$lock" ] || fail "a free lock was not acquired: $(cat "$out")"
[ "$(cat "$lock/pid")" = "$$" ] || fail "lock does not record the holder pid"
ci_host_lock_release
[ ! -e "$lock" ] || fail "release left the lock behind"

# A live sibling holds it: wait, then run WITHOUT it and say so.
mkdir -p "$lock"; sleep 300 & sibling=$!; echo "$sibling" >"$lock/pid"; echo "EdgeVector/last-stack run=9" >"$lock/owner"
ci_host_lock_acquire "$lock" 2 3600 1 >"$out"
kill "$sibling" 2>/dev/null || true; wait "$sibling" 2>/dev/null || true
[ -z "$CI_HOST_LOCK_HELD" ] || fail "took a lock a live sibling holds"
grep -q 'ci_host_lock NOT acquired after 2s (holder: EdgeVector/last-stack run=9); running without it' "$out" \
  || fail "a timed-out wait was not reported: $(cat "$out")"
ci_host_lock_release
[ -d "$lock" ] || fail "release removed a lock this process does not hold"

# The sibling was SIGKILLed (dead pid): take the lock over.
ci_host_lock_acquire "$lock" 5 3600 0 >"$out"
grep -q 'ci_host_lock stale' "$out" || fail "a dead holder was not detected: $(cat "$out")"
[ "$CI_HOST_LOCK_HELD" = "$lock" ] || fail "a stale lock was not taken over"
ci_host_lock_release

# --- Case 4: the failing-shard marker names the cause ----------------------
# A shard whose status was non-zero with no failing test used to render as a
# bare "FAILED", so the reader grepped a log in which every test passed. These
# cases are hermetic on purpose: the classification reads a LOG, not a process,
# so a crafted log is the whole fixture and the case costs no wall clock.
# papercut-ci-shard-exits-non-zero-with-no-failing-test-and-renders-as-a-plain-failed-20261003
logs="$TMP_ROOT/case4"
mkdir -p "$logs"

# 4a: a genuine red test.
cat >"$logs/0.log" <<'LOG'
ci_test start: tests/a.sh
ci_test done: tests/a.sh rc=0 secs=1
ci_test start: tests/b.sh
ci_test done: tests/b.sh rc=1 secs=2
LOG
marker="$(ci_shard_failure_marker 0 1 "$logs/0.log" "")"
case "$marker" in
  *"shard 0 FAILED (exit 1)"*) ;;
  *) fail "a red test must render as FAILED with its exit status: $marker" ;;
esac
case "$marker" in
  *"NO FAILING TEST"*) fail "a red test was reported as having no failing test: $marker" ;;
esac

# 4b: non-zero status, every test green. The case the papercut measured.
# The log also carries the three strings that made the real log misleading to
# grep -- fixture FAIL lines and an rc=1 that is not a `ci_test done` line. A
# classifier that greps for "FAIL" or "rc=1" anywhere passes 4a and fails here,
# which is why the negative fixture supplies WRONG values and not absent ones.
cat >"$logs/1.log" <<'LOG'
ci_test start: tests/a.sh
FAIL: north-star-lastgit-pack-blobs-b2-migration
FAIL machine-leak: 1 new soft host-identity hit
host-track: probe attempt 1/3 failed ... rc=1
ci_test done: tests/a.sh rc=0 secs=1
ci_test start: tests/b.sh
ci_test done: tests/b.sh rc=0 secs=3
LOG
marker="$(ci_shard_failure_marker 1 143 "$logs/1.log" "")"
case "$marker" in
  *"shard 1 EXITED NON-ZERO WITH NO FAILING TEST (exit 143)"*) ;;
  *) fail "a shard that died with no red test must say so, and name its status: $marker" ;;
esac
case "$marker" in
  *"128+N is a signal"*) ;;
  *) fail "the marker must tell the reader what a 128+N status means: $marker" ;;
esac
case "$marker" in
  *"shard 1 FAILED"*) fail "a shard with no failing test still rendered as FAILED: $marker" ;;
esac

# 4c: the deadline arm wins, and it also carries the status now. A timeout must
# never be relabelled as "no failing test" -- its log legitimately has none.
marker="$(ci_shard_failure_marker 1 143 "$logs/1.log" " 1 ")"
case "$marker" in
  *"shard 1 STOPPED AT DEADLINE (a timeout, not a test failure; exit 143)"*) ;;
  *) fail "a shard stopped at the deadline must still say timeout, with its status: $marker" ;;
esac
case "$marker" in
  *"NO FAILING TEST"*) fail "a deadline stop was reclassified as no failing test: $marker" ;;
esac

# 4d: a multi-digit rc is a failing test. `rc=[1-9]` alone would be enough here,
# but a pattern anchored on a single digit would miss rc=10 and silently move a
# red shard into the "no failing test" class, which is the worse direction.
cat >"$logs/2.log" <<'LOG'
ci_test start: tests/c.sh
ci_test done: tests/c.sh rc=10 secs=1
LOG
marker="$(ci_shard_failure_marker 2 10 "$logs/2.log" "")"
case "$marker" in
  *"shard 2 FAILED (exit 10)"*) ;;
  *) fail "rc=10 is a failing test: $marker" ;;
esac

# 4e: the predicate on its own, both directions, so a change to the marker's
# wording cannot hide a change to what it classifies.
ci_shard_has_failing_test "$logs/0.log" || fail "a log with rc=1 has a failing test"
if ci_shard_has_failing_test "$logs/1.log"; then fail "fixture FAIL text is not a failing test"; fi

# --- Wiring: the gate uses the supervisor and exits 124 on a deadline ------
CI="$ROOT/.lastgit/ci.sh"
grep -Fq '. "$ROOT/lib/ci-shard-supervisor.sh"' "$CI" || fail "ci.sh does not source the supervisor"
grep -Fq 'ci_supervise_shards "$CI_SHARD_LOG_DIR"' "$CI" || fail "ci.sh does not supervise its shards"
grep -Fq 'exit 124' "$CI" || fail "ci.sh does not exit 124 on a deadline"
grep -Fq 'ci_host_lock_acquire' "$CI" || fail "ci.sh does not take the host lock"
grep -Fq 'LAST_STACK_CI_HOST_LOCK:-0' "$CI" || fail "ci.sh no longer lets a Mac host job opt into the host lock"
grep -Fq 'echo "ci_test done: $* rc=${ci_test_rc} secs=' "$CI" || fail "ci_test does not print a done line"
# The status `wait` produces must reach the marker. Without these two the gate
# can keep every classification branch and still print "exit ?" for all of them,
# or drop the marker call and fall back to a bare FAILED.
grep -Fq 'wait "$shard_pid" || shard_rc=$?' "$CI" || fail "ci.sh discards each shard's exit status"
grep -Fq 'ci_shard_failure_marker "$failed_index"' "$CI" || fail "ci.sh does not classify a failing shard"
# A main push must never cancel the earlier main publish run
# (papercut-forge-main-publish-starved-by-cancel-in-progress-20260922). Without
# this rule a push cancels the earlier main run and host-track stops getting
# installs. The GitHub workflow cancels only pull_request runs.
grep -Fq "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$ROOT/.github/workflows/ci-required.yml" \
  || fail "the GitHub workflow lets a main push cancel the main publish run"

echo "ok last-stack-ci-shard-supervisor"
