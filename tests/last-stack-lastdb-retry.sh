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

echo "PASS=$pass FAIL=$fail"
test "$fail" -eq 0
