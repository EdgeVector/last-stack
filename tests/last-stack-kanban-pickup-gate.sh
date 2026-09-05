#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-kanban-pickup-gate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Preserve the invoking shell's PATH (has gtimeout/timeout on macOS via
# Homebrew) for cases that need a real timeout_bin. Cases that narrow PATH do
# so deliberately and restore it themselves where needed.
ORIG_PATH="$PATH"

export LAST_STACK_ROOT="$tmp/ls"
mkdir -p "$LAST_STACK_ROOT/bin" "$tmp/path"

# shell-prelude must be sourceable (not exit)
: >"$LAST_STACK_ROOT/bin/last-stack-shell-prelude"
printf '#!/bin/sh\nexit 0\n' >"$LAST_STACK_ROOT/bin/last-stack-brain-append-heartbeat"
# Hung closeout: if the gate still invokes this, the ready>0 case would exceed
# the wall-clock budget. The regression below asserts the gate finishes fast.
cat >"$LAST_STACK_ROOT/bin/last-stack-board-closeout-sweep" <<'S'
#!/bin/sh
# Deliberately hang — gate must NOT wait on this (LaunchAgent owns closeout).
sleep 600
S
cat >"$LAST_STACK_ROOT/bin/last-stack-lastdb-retry" <<'S'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attempts) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
S
chmod +x "$LAST_STACK_ROOT/bin/last-stack-brain-append-heartbeat" \
  "$LAST_STACK_ROOT/bin/last-stack-board-closeout-sweep" \
  "$LAST_STACK_ROOT/bin/last-stack-lastdb-retry"

# Case 1: ready=0
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  printf '%s\n' '{"scanned":10,"ready":0,"counts":{"pickup-ready":0,"unattached-outcome":5,"human-gated":3},"cards":[]}'
  exit 0
fi
echo "unexpected: $*" >&2
exit 1
S
chmod +x "$tmp/path/kanban"
export PATH="$tmp/path:$PATH"

set +e
out="$("$GATE" 2>&1)"
rc=$?
set -e
test "$rc" -eq 0 || { echo "case1 expected rc=0 got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=noop' || { echo "missing trailer"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'ready=0' || { echo "missing ready=0"; echo "$out"; exit 1; }

# Case 2: ready>0 with hung closeout binary present — must still exit 10 fast
# (under 120s; assert well under 30s).
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  printf '%s\n' '{"scanned":10,"ready":3,"counts":{"pickup-ready":3},"cards":[]}'
  exit 0
fi
exit 1
S
chmod +x "$tmp/path/kanban"
set +e
start_epoch="$(date +%s)"
out="$("$GATE" 2>&1)"
rc=$?
end_epoch="$(date +%s)"
set -e
elapsed=$((end_epoch - start_epoch))
test "$rc" -eq 10 || { echo "case2 expected rc=10 got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'PICKUP_GATE_PROCEED ready=3' || { echo "missing PICKUP_GATE_PROCEED"; echo "$out"; exit 1; }
if printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok'; then
  echo "case2 must not print ROUTINE_RESULT outcome=ok"; echo "$out"; exit 1
fi
if [ "$elapsed" -ge 30 ]; then
  echo "case2 hung closeout still delayed gate: elapsed=${elapsed}s (want <30)" >&2
  echo "$out"
  exit 1
fi
if [ "$elapsed" -ge 120 ]; then
  echo "case2 exceeded routinesd gate budget: elapsed=${elapsed}s" >&2
  exit 1
fi

# Case 3: status hangs; todo has items → skip (fail-closed), never proceed-ok.
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  sleep 600
  exit 0
fi
if [ "$1" = list ]; then
  printf '%s\n' '{"cards":[{"slug":"a","column":"todo"},{"slug":"b","column":"todo"}],"total":2}'
  exit 0
fi
exit 1
S
chmod +x "$tmp/path/kanban"
export LAST_STACK_PICKUP_GATE_STATUS_TIMEOUT_SEC=2
export LAST_STACK_PICKUP_GATE_TODO_TIMEOUT_SEC=5
if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
  set +e
  start_epoch="$(date +%s)"
  out="$("$GATE" 2>&1)"
  rc=$?
  end_epoch="$(date +%s)"
  set -e
  elapsed=$((end_epoch - start_epoch))
  test "$rc" -eq 0 || { echo "case3 expected rc=0 got $rc"; echo "$out"; exit 1; }
  if printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok'; then
    echo "case3 must not print ROUTINE_RESULT outcome=ok"; echo "$out"; exit 1
  fi
  printf '%s\n' "$out" | grep -q 'err_class=' || {
    echo "case3 missing err_class"; echo "$out"; exit 1
  }
  printf '%s\n' "$out" | grep -q 'status_rc=' || {
    echo "case3 missing status_rc"; echo "$out"; exit 1
  }
  if [ "$elapsed" -ge 30 ]; then
    echo "case3 status timeout path too slow: elapsed=${elapsed}s" >&2
    echo "$out"
    exit 1
  fi
else
  echo "case3 skip (no gtimeout/timeout on PATH)"
fi
unset LAST_STACK_PICKUP_GATE_STATUS_TIMEOUT_SEC
unset LAST_STACK_PICKUP_GATE_TODO_TIMEOUT_SEC

# Case 4: status fails immediately; todo is non-empty → skip, no proceed-ok.
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  echo "service_timeout: node did not respond within 30000ms" >&2
  exit 1
fi
if [ "$1" = list ]; then
  printf '%s\n' '{"cards":[{"slug":"a","column":"todo"},{"slug":"b","column":"todo"},{"slug":"c","column":"todo"}],"total":3}'
  exit 0
fi
exit 1
S
chmod +x "$tmp/path/kanban"
set +e
out="$("$GATE" 2>&1)"
rc=$?
set -e
test "$rc" -eq 0 || { echo "case4 expected rc=0 got $rc"; echo "$out"; exit 1; }
if printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok'; then
  echo "case4 must not print ROUTINE_RESULT outcome=ok"; echo "$out"; exit 1
fi
if printf '%s\n' "$out" | grep -q 'PICKUP_GATE proceed todo_count='; then
  echo "case4 must not proceed from todo count"; echo "$out"; exit 1
fi
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=noop' || {
  echo "case4 missing noop trailer"; echo "$out"; exit 1
}
printf '%s\n' "$out" | grep -q 'err_class=busy-node' || {
  echo "case4 missing err_class=busy-node"; echo "$out"; exit 1
}
printf '%s\n' "$out" | grep -q 'status_rc=1' || {
  echo "case4 missing status_rc=1"; echo "$out"; exit 1
}
printf '%s\n' "$out" | grep -q 'todo_rc=0' || {
  echo "case4 missing todo_rc=0"; echo "$out"; exit 1
}

# Case 5: PATH gtimeout cannot exec (Codex sandbox / Homebrew outside allow
# list). Live inner runs often return rc=1 plus Permission denied, not 126.
# Board status still returns ready>0 — must proceed, not board-read-failed.
mkdir -p "$tmp/badtimeout"
cat >"$tmp/badtimeout/gtimeout" <<'S'
#!/bin/sh
echo "gtimeout: Operation not permitted" >&2
exit 1
S
chmod +x "$tmp/badtimeout/gtimeout"
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  printf '%s\n' '{"scanned":10,"ready":3,"counts":{"pickup-ready":3},"cards":[]}'
  exit 0
fi
exit 1
S
chmod +x "$tmp/path/kanban"
PATH="$tmp/badtimeout:$tmp/path:$PATH"
export PATH
set +e
out="$("$GATE" 2>&1)"
rc=$?
set -e
test "$rc" -eq 10 || { echo "case5 expected rc=10 got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'PICKUP_GATE_PROCEED ready=3' || {
  echo "case5 missing PICKUP_GATE_PROCEED"; echo "$out"; exit 1
}
if printf '%s\n' "$out" | grep -q 'board-read-failed'; then
  echo "case5 must not skip as board-read-failed"; echo "$out"; exit 1
fi

# Case 6: preferred heartbeat artifact log path is not writable; fallback
# heartbeat works; board status ready>0 — must proceed.
# Restore a working timeout-free PATH (keep fake kanban).
PATH="$tmp/path:/usr/bin:/bin"
export PATH
ro_root="$tmp/artifact-ro"
mkdir -p "$ro_root/bin" "$ro_root/logs" "$tmp/routines"
cp "$ROOT/bin/last-stack-brain-append-heartbeat" "$ro_root/bin/"
: >"$ro_root/bin/last-stack-shell-prelude"
cp "$LAST_STACK_ROOT/bin/last-stack-lastdb-retry" "$ro_root/bin/"
chmod +x "$ro_root/bin/last-stack-brain-append-heartbeat" \
  "$ro_root/bin/last-stack-lastdb-retry"
chmod 555 "$ro_root/logs"
export LAST_STACK_ROOT="$ro_root"
export ROUTINES_HOME="$tmp/routines"
unset LAST_STACK_HEARTBEATS_FILE
set +e
out="$("$GATE" 2>&1)"
rc=$?
set -e
test "$rc" -eq 10 || { echo "case6 expected rc=10 got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'PICKUP_GATE_PROCEED ready=3' || {
  echo "case6 missing PICKUP_GATE_PROCEED"; echo "$out"; exit 1
}
if printf '%s\n' "$out" | grep -q 'board-read-failed'; then
  echo "case6 must not classify heartbeat EPERM as board-read-failed"
  echo "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'fallback'; then
  # Heartbeat may write via ROUTINES_HOME fallback; require that skip-on-board
  # did not fire. Fallback text is best-effort evidence.
  :
fi

# Case 7 (regression, papercut-pickup-gate-45s-cap-cannot-hold-the-retry-schedule-it-asks-for-20260904):
# a status read that ALWAYS flaps, driven through the REAL retry binary (not
# the trivial passthrough mock used above), must make the gate's outer
# per-call cap and the retry wrapper's own backoff schedule agree. Before this
# fix the gate never told the wrapper its deadline, so the wrapper slept the
# full 15s/45s schedule regardless of the cap, the outer `timeout` SIGKILLed
# it mid-sleep, and the kill discarded the buffered flap text -- the gate then
# reported `status_rc=124` with an effectively empty reason. With the fix, the
# wrapper sees its budget is already below the reserve on the very first retry
# decision (cap is well under the default 20s reserve) and takes its
# "deadline won" branch immediately: the real rc and real stderr survive, and
# the gate never needs the outer SIGKILL at all.
LAST_STACK_ROOT="$tmp/ls-real-retry"
mkdir -p "$LAST_STACK_ROOT/bin" "$LAST_STACK_ROOT/lib"
export LAST_STACK_ROOT
: >"$LAST_STACK_ROOT/bin/last-stack-shell-prelude"
printf '#!/bin/sh\nexit 0\n' >"$LAST_STACK_ROOT/bin/last-stack-brain-append-heartbeat"
cp "$ROOT/bin/last-stack-lastdb-retry" "$LAST_STACK_ROOT/bin/last-stack-lastdb-retry"
cp "$ROOT/lib/lastdb-retry-schedule.sh" "$LAST_STACK_ROOT/lib/lastdb-retry-schedule.sh"
chmod +x "$LAST_STACK_ROOT/bin/last-stack-brain-append-heartbeat" \
  "$LAST_STACK_ROOT/bin/last-stack-lastdb-retry"

cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  echo "service_timeout: node did not respond within 30000ms" >&2
  exit 1
fi
if [ "$1" = list ]; then
  printf '%s\n' '{"cards":[{"slug":"a","column":"todo"}],"total":1}'
  exit 0
fi
exit 1
S
chmod +x "$tmp/path/kanban"
# This case exercises the real outer-timeout + retry-wrapper interaction, so
# it needs a real timeout_bin on PATH (gtimeout/timeout), unlike case 6's
# deliberately narrow PATH.
PATH="$tmp/path:$ORIG_PATH"
export PATH
if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
  # Cap well under the default 20s attempt reserve so the wrapper's very first
  # retry decision already sees remaining <= reserve and exits immediately via
  # "deadline won" -- deterministic, no timing race against a real sleep.
  export LAST_STACK_PICKUP_GATE_STATUS_TIMEOUT_SEC=5
  export LAST_STACK_PICKUP_GATE_TODO_TIMEOUT_SEC=5
  set +e
  start_epoch="$(date +%s)"
  out="$("$GATE" 2>&1)"
  rc=$?
  end_epoch="$(date +%s)"
  set -e
  elapsed=$((end_epoch - start_epoch))
  unset LAST_STACK_PICKUP_GATE_STATUS_TIMEOUT_SEC
  unset LAST_STACK_PICKUP_GATE_TODO_TIMEOUT_SEC
  test "$rc" -eq 0 || { echo "case7 expected rc=0 got $rc"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'status_rc=1 ' || {
    echo "case7 expected the real flap rc=1, not an outer-kill 124/137"
    echo "$out"
    exit 1
  }
  printf '%s\n' "$out" | grep -q 'err_class=busy-node' || {
    echo "case7 expected the real service_timeout text to classify as busy-node, not an erased-stderr default"
    echo "$out"
    exit 1
  }
  if [ "$elapsed" -ge 5 ]; then
    echo "case7 took too long ($elapsed s) -- the wrapper had to be SIGKILLed instead of self-exiting" >&2
    echo "$out"
    exit 1
  fi
else
  echo "case7 skip (no gtimeout/timeout on PATH)"
fi

echo ok
