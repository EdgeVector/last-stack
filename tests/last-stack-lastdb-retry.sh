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

echo "PASS=$pass FAIL=$fail"
test "$fail" -eq 0
