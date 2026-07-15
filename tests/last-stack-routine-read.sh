#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" kanban-pickup)"
case "$prompt" in
  *"name: kanban-pickup"*|*"ready board queue"*) ;;
  *)
    echo "expected kanban-pickup prompt text" >&2
    exit 1
    ;;
esac

dogfood_prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" dogfood-rotate)"
case "$dogfood_prompt" in
  *"Retired / ineligible auto-rotation surfaces"*|*"status: retired"*"eligible: false"*"auto-rotation: false"*) ;;
  *)
    echo "expected dogfood-rotate prompt to exclude retired registry surfaces" >&2
    exit 1
    ;;
esac
case "$dogfood_prompt" in
  *"error-dirty"*"warn: last-stack-checkout-dirty"*"noop heartbeat"*"reason=last-stack-checkout-dirty"*) ;;
  *)
    echo "expected dogfood-rotate prompt to treat dirty install checkout as noop, not error" >&2
    exit 1
    ;;
esac

if LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" does-not-exist >/dev/null 2>"/tmp/last-stack-routine-read-missing.$$"; then
  echo "expected missing routine to fail" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_MISSING' "/tmp/last-stack-routine-read-missing.$$"
rm -f "/tmp/last-stack-routine-read-missing.$$"

if "$ROOT/bin/last-stack-routine-read" "../kanban-pickup" >/dev/null 2>"/tmp/last-stack-routine-read-invalid.$$"; then
  echo "expected invalid routine name to fail" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_INVALID' "/tmp/last-stack-routine-read-invalid.$$"
rm -f "/tmp/last-stack-routine-read-invalid.$$"

echo "ok"
