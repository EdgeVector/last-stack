#!/usr/bin/env bash
# Unit tests for last-stack-lastdb-retry — drive the real binary.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-retry"
chmod +x "$BIN"

fail=0
pass=0
assert() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name" >&2
    fail=$((fail + 1))
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 1) success on first try
out="$("$BIN" --attempts 3 -- true)"
assert "true exits 0" test $? -eq 0

# 2) transient flap then success
cat >"$tmpdir/flap_then_ok.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
if [ "$n" -lt 3 ]; then
  echo "service_timeout: node did not respond within 30000ms" >&2
  exit 1
fi
echo "ok-on-attempt-$n"
exit 0
SH
chmod +x "$tmpdir/flap_then_ok.sh"
export RETRY_COUNT_FILE="$tmpdir/count1"
out="$("$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/flap_then_ok.sh")"
assert "retries service_timeout then succeeds" test "$out" = "ok-on-attempt-3"
assert "took 3 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "3"

# 3) max_outbox_entries is NOT retried
cat >"$tmpdir/outbox.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
echo "board_write_rejected max_outbox_entries_100000" >&2
exit 1
SH
chmod +x "$tmpdir/outbox.sh"
export RETRY_COUNT_FILE="$tmpdir/count2"
set +e
"$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/outbox.sh" >/dev/null 2>&1
rc=$?
set -e
assert "outbox fails fast non-zero" test "$rc" -ne 0
assert "outbox not retried (1 attempt)" test "$(cat "$RETRY_COUNT_FILE")" = "1"

# 4) permanent failure after attempts exhausted
cat >"$tmpdir/always_timeout.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
echo "too many concurrent reads" >&2
exit 7
SH
chmod +x "$tmpdir/always_timeout.sh"
export RETRY_COUNT_FILE="$tmpdir/count3"
set +e
"$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/always_timeout.sh" >/dev/null 2>&1
rc=$?
set -e
assert "exhausted retries keep exit code" test "$rc" -eq 7
assert "ran 3 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "3"

# 5) persist_queue_full IS retried, and the exec id printed on stdout before
#    the Error line does not hide it. On 2026-08-27 a caller that asked for 30
#    attempts got exactly one, because the matcher had no persist_queue_full
#    (papercut-last-stack-lastdb-retry-does-not-match-persist-queue-full).
cat >"$tmpdir/persist_queue.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
if [ "$n" -lt 3 ]; then
  # The real shape: loom prints the execution id first, then the node answer.
  echo "lx-ship-north-star-0f1e2d"
  echo 'Error: mutation on LoomAgent -> HTTP 503: {"error":"persist_queue_full","kind":"bytes","message":"persist queue full for schema '"'"'6fcb6bd1'"'"' (bytes); retry after drain","ok":false,"retryable":true}' >&2
  exit 1
fi
echo "ok-on-attempt-$n"
exit 0
SH
chmod +x "$tmpdir/persist_queue.sh"
export RETRY_COUNT_FILE="$tmpdir/count4"
out="$("$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/persist_queue.sh")"
assert "retries persist_queue_full then succeeds" \
  test "$(printf '%s' "$out" | tail -n 1)" = "ok-on-attempt-3"
assert "persist_queue_full took 3 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "3"

# 5b) the bounded post-ack CAPTURE queue is the same backpressure typed as a
#     400 with no `"retryable": true`. Case 6 below proves a bare 400 is NOT
#     retried, which is why this shape needs its own match: on 2026-08-30T08:23Z
#     `loom run ... attempts=3` ended `rc=1 after 1 attempt(s)` on this exact
#     string and last-stack-whats-wrong recorded outcome=error.
cat >"$tmpdir/capture_queue.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
if [ "$n" -lt 3 ]; then
  echo "lx-20260830T083641.548-20943-1"
  echo 'Error: mutation on LoomExecution -> HTTP 400: "Invalid data: Storage backend error: mutation capture queue remained full for 100ms; retry before local commit"' >&2
  exit 1
fi
echo "ok-on-attempt-$n"
exit 0
SH
chmod +x "$tmpdir/capture_queue.sh"
export RETRY_COUNT_FILE="$tmpdir/count4b"
out="$("$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/capture_queue.sh")"
assert "retries capture-queue-full 400 then succeeds" \
  test "$(printf '%s' "$out" | tail -n 1)" = "ok-on-attempt-3"
assert "capture-queue-full took 3 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "3"

# 6) a node answer that says retryable:false is NOT retried
cat >"$tmpdir/not_retryable.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
echo 'Error: HTTP 400: {"error":"bad_request","ok":false,"retryable":false}' >&2
exit 1
SH
chmod +x "$tmpdir/not_retryable.sh"
export RETRY_COUNT_FILE="$tmpdir/count5"
set +e
"$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/not_retryable.sh" >/dev/null 2>&1
set -e
assert "retryable:false not retried (1 attempt)" test "$(cat "$RETRY_COUNT_FILE")" = "1"

# 7) a broken pipe on the unix socket IS retried.
#    2026-08-27T21:38Z: `last-stack-whats-wrong` lost a whole hourly heal pass
#    to one line — `Error: Broken pipe (os error 32)` from `loom run`, rc=1,
#    reported as `exceptions=8 healed=0 loom-run-failed rc=1`. A broken pipe on
#    the UDS is the same family as ECONNRESET, which this matcher already
#    treats as transient; `loom ping` answered ok immediately afterwards. The
#    Rust wording carries no errno name, so match the text AND `os error 32`.
cat >"$tmpdir/broken_pipe.sh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$RETRY_COUNT_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" >"$RETRY_COUNT_FILE"
if [ "$n" -lt 2 ]; then
  echo 'Error: Broken pipe (os error 32)' >&2
  exit 1
fi
echo ok
SH
chmod +x "$tmpdir/broken_pipe.sh"
export RETRY_COUNT_FILE="$tmpdir/count6"
assert "retries a broken pipe then succeeds" \
  "$BIN" --attempts 3 --sleep-ms 50 -- "$tmpdir/broken_pipe.sh"
assert "broken pipe took 2 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "2"

# 8) shared drain schedule (fails on the old 3x750ms defaults)
# shellcheck source=lib/lastdb-retry-schedule.sh
. "$ROOT/lib/lastdb-retry-schedule.sh"
assert "default attempts is 5" test "$(last_stack_lastdb_retry_default_attempts)" = "5"
assert "schedule slot 1 is 15" test "$(last_stack_lastdb_retry_sleep_sec 1)" = "15"
assert "schedule slot 2 is 45" test "$(last_stack_lastdb_retry_sleep_sec 2)" = "45"
assert "schedule slot 3 is 90" test "$(last_stack_lastdb_retry_sleep_sec 3)" = "90"
assert "schedule slot 4 is 120" test "$(last_stack_lastdb_retry_sleep_sec 4)" = "120"

cat >"$tmpdir/persist_queue_twice.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
if [ "$n" -lt 3 ]; then
  echo 'Error: HTTP 503: {"error":"persist_queue_full","retryable":true}' >&2
  exit 1
fi
echo "ok-on-attempt-$n"
exit 0
SH
chmod +x "$tmpdir/persist_queue_twice.sh"
export RETRY_COUNT_FILE="$tmpdir/count-drain"
unset LAST_STACK_LASTDB_RETRY_SLEEP_SEC
unset LAST_STACK_LASTDB_RETRY_ATTEMPTS
export LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC="0,0,0,0"
set +e
drain_err="$tmpdir/drain.err"
out="$("$BIN" -- "$tmpdir/persist_queue_twice.sh" 2>"$drain_err")"
drain_rc=$?
set -e
assert "schedule persist_queue_full twice then succeeds" test "$drain_rc" -eq 0
assert "schedule took 3 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "3"
assert "stdout is success" test "$out" = "ok-on-attempt-3"
wait_lines="$(grep -c 'drain wait attempt=' "$drain_err" || true)"
assert "two drain waits logged" test "$wait_lines" = "2"
assert "ended with drain-finished log" grep -q 'succeeded after 2 drain wait(s)' "$drain_err"

cat >"$tmpdir/persist_queue_four.sh" <<'SH'
#!/usr/bin/env bash
nfile="${RETRY_COUNT_FILE:?}"
n=$(cat "$nfile" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$nfile"
if [ "$n" -lt 5 ]; then
  echo 'Error: HTTP 503: {"error":"persist_queue_full","retryable":true}' >&2
  exit 1
fi
echo "ok-on-attempt-$n"
exit 0
SH
chmod +x "$tmpdir/persist_queue_four.sh"
export RETRY_COUNT_FILE="$tmpdir/count-drain5"
set +e
"$BIN" -- "$tmpdir/persist_queue_four.sh" >/dev/null 2>"$tmpdir/drain5.err"
d5_rc=$?
set -e
assert "default 5 attempts survive 4 persist_queue_full" test "$d5_rc" -eq 0
assert "default schedule took 5 attempts" test "$(cat "$RETRY_COUNT_FILE")" = "5"

# 9) capped_sleep_sec reserves room for the NEXT attempt's call cost, not just
# one second (papercut-pickup-gate-45s-cap-cannot-hold-the-retry-schedule-it-asks-for-20260904).
# Deterministic: drive the epoch math directly, no real sleeping.
# Test 8 left LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC=0,0,0,0 exported; clear it
# (and the other schedule knobs) so this section sees the real defaults.
unset LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC
unset LAST_STACK_LASTDB_RETRY_SLEEP_SEC
assert "default attempt reserve is 20" \
  test "$(last_stack_lastdb_retry_attempt_reserve_sec)" = "20"
unset LAST_STACK_LASTDB_RETRY_ATTEMPT_RESERVE_SEC

# Each sub-test recomputes `now` right before use (not once at the top): the
# capped-sleep math is wall-clock-sensitive, and the asserts above this point
# take real (if small) time, so a stale `now` intermittently drifts a boundary
# case (e.g. remaining=25 becoming remaining=24) across an exact-equality
# assert.

# Plenty of budget: the request passes through unclamped.
LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(($(date -u +%s) + 100))
assert "ample budget: request passes through" \
  test "$(last_stack_lastdb_retry_capped_sleep_sec 15)" = "15"

# Moderate budget (~25s left, reserve 20s -> cap ~5s): a bigger request is
# clamped DOWN, not to "remaining-1" (~24s), but to the reserve-aware cap.
# Tolerate +/-1s of real wall-clock drift between the two `date` reads
# instead of asserting an exact value.
LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(($(date -u +%s) + 25))
moderate_cap="$(last_stack_lastdb_retry_capped_sleep_sec 45)"
assert "moderate budget clamps to reserve-aware cap (~5s), not remaining-1 (~24s)" \
  test "$moderate_cap" -ge 4 -a "$moderate_cap" -le 6

# Budget at or below the reserve: no more sleeping, take the deadline-won
# branch immediately instead of sleeping into the outer kill.
LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(($(date -u +%s) + 20))
assert "budget == reserve returns 0 (deadline won)" \
  test "$(last_stack_lastdb_retry_capped_sleep_sec 15)" = "0"
LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(($(date -u +%s) + 5))
assert "budget under reserve returns 0 (deadline won)" \
  test "$(last_stack_lastdb_retry_capped_sleep_sec 15)" = "0"

# Reserve is configurable — a caller with a cheaper/known call cost can shrink
# it, and the cap follows.
LAST_STACK_LASTDB_RETRY_ATTEMPT_RESERVE_SEC=5
LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(($(date -u +%s) + 25))
custom_cap="$(last_stack_lastdb_retry_capped_sleep_sec 45)"
assert "custom reserve changes the cap (~20s)" \
  test "$custom_cap" -ge 19 -a "$custom_cap" -le 21
unset LAST_STACK_LASTDB_RETRY_ATTEMPT_RESERVE_SEC
unset LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH

# 10) End-to-end: a caller that wraps this binary in an outer `timeout` and
# exports the deadline must get the REAL rc and REAL stderr back, and must
# finish comfortably inside the outer cap -- not be SIGKILLed mid-sleep with
# its buffered error erased. This is the gate's exact failure shape from the
# papercut repro: a stub that sleeps then fails with a flap string, wrapped in
# `timeout -k 3s <cap>s`, default schedule (15s first sleep) far exceeds a
# short cap unless the wrapper self-terminates via "deadline won" first.
if command -v gtimeout >/dev/null 2>&1; then
  TO=gtimeout
elif command -v timeout >/dev/null 2>&1; then
  TO=timeout
else
  TO=""
fi
if [ -n "$TO" ]; then
  cat >"$tmpdir/always_flap_fast.sh" <<'SH'
#!/usr/bin/env bash
echo "service_timeout: node did not respond within 30000ms" >&2
exit 1
SH
  chmod +x "$tmpdir/always_flap_fast.sh"
  cap_sec=6
  deadline_err="$tmpdir/deadline.err"
  start_epoch="$(date +%s)"
  set +e
  LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH=$(( $(date -u +%s) + cap_sec )) \
    "$TO" -k 3s "${cap_sec}s" "$BIN" --attempts 5 -- "$tmpdir/always_flap_fast.sh" \
    >/dev/null 2>"$deadline_err"
  deadline_rc=$?
  set -e
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - start_epoch))
  assert "budget-capped run exits with the real rc, not an outer timeout kill" \
    test "$deadline_rc" -eq 1
  assert "budget-capped run finishes at or under the outer cap" \
    test "$elapsed" -le "$cap_sec"
  assert "budget-capped run's stderr is not empty" \
    test -s "$deadline_err"
  assert "budget-capped run's stderr keeps the real flap reason" \
    grep -q 'service_timeout' "$deadline_err"
  assert "budget-capped run logs deadline won, not a silent kill" \
    grep -q 'deadline won' "$deadline_err"
else
  echo "case 10 skip (no gtimeout/timeout on PATH)"
fi

echo "PASS=$pass FAIL=$fail"
test "$fail" -eq 0
