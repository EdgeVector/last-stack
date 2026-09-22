#!/usr/bin/env bash
# Behaviour of lib/ci-shard-supervisor.sh, the heartbeat and internal deadline
# of the required gate's shard runner.
#
# A Forge timeout kill used to leave a job log with zero shard output, which
# read as a test failure
# (papercut-last-stack-ci-deadline-kill-reports-as-test-failure-with-no-shard-output-20260922).
# Pins that: a heartbeat names each shard's running test; the deadline names the
# stuck test, sets CI_SUPERVISE_TIMED_OUT, and stops the shard AND its child;
# fast shards finish with no timeout. Hermetic: fake shards, no network. ~6s.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
grep -q '^ci_progress elapsed=' "$out" || fail "no heartbeat before the deadline: $(cat "$out")"
grep -q 'shard 1: running tests/stuck.sh' "$out" || fail "heartbeat did not name the running test"

if kill -0 "$stuck_pid" 2>/dev/null; then fail "stuck shard still alive after the deadline"; fi
child_pid="$(cat "$child_pid_file" 2>/dev/null || true)"
[ -n "$child_pid" ] || fail "fixture did not record its child pid"
if kill -0 "$child_pid" 2>/dev/null; then
  kill -KILL "$child_pid" 2>/dev/null || true
  fail "the stuck shard's child survived; the stop must reach the process group"
fi
wait "$fast_pid" || fail "fast shard exit code lost"
if wait "$stuck_pid"; then fail "a stopped shard reported success"; fi

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

# --- Wiring: the gate uses the supervisor and exits 124 on a deadline ------
CI="$ROOT/.lastgit/ci.sh"
grep -Fq '. "$ROOT/lib/ci-shard-supervisor.sh"' "$CI" || fail "ci.sh does not source the supervisor"
grep -Fq 'ci_supervise_shards "$CI_SHARD_LOG_DIR"' "$CI" || fail "ci.sh does not supervise its shards"
grep -Fq 'exit 124' "$CI" || fail "ci.sh does not exit 124 on a deadline"
grep -Fq 'echo "ci_test done: $* rc=${ci_test_rc} secs=' "$CI" || fail "ci_test does not print a done line"

echo "ok last-stack-ci-shard-supervisor"
