#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-kanban-pickup-gate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
printf '%s\n' "$out" | grep -q 'proceed ready=3' || { echo "missing proceed"; echo "$out"; exit 1; }
if [ "$elapsed" -ge 30 ]; then
  echo "case2 hung closeout still delayed gate: elapsed=${elapsed}s (want <30)" >&2
  echo "$out"
  exit 1
fi
if [ "$elapsed" -ge 120 ]; then
  echo "case2 exceeded routinesd gate budget: elapsed=${elapsed}s" >&2
  exit 1
fi

# Case 3: status hangs; todo fallback has items → proceed under status timeout.
# Use a 2s status cap so the test stays fast.
cat >"$tmp/path/kanban" <<'S'
#!/bin/sh
if [ "$1" = pickup ] && [ "$2" = status ]; then
  sleep 600
  exit 0
fi
if [ "$1" = list ]; then
  # todo list shape used by gate fallback: JSON array length
  printf '%s\n' '[{"slug":"a","column":"todo"},{"slug":"b","column":"todo"}]'
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
  test "$rc" -eq 10 || { echo "case3 expected rc=10 got $rc"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'status_unavailable' || {
    echo "case3 missing status_unavailable fallback"; echo "$out"; exit 1
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

echo ok
