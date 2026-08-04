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
printf '#!/bin/sh\nexit 0\n' >"$LAST_STACK_ROOT/bin/last-stack-board-closeout-sweep"
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

# Case 2: ready>0
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
out="$("$GATE" 2>&1)"
rc=$?
set -e
test "$rc" -eq 10 || { echo "case2 expected rc=10 got $rc"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -q 'proceed ready=3' || { echo "missing proceed"; echo "$out"; exit 1; }

echo ok
