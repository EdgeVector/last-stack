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
case "$prompt" in
  *"must not create a new"*"synthetic idle card and then claim/work that same card"*) ;;
  *)
    echo "expected kanban-pickup idle fallback to file-and-exit instead of self-claiming synthetic work" >&2
    exit 1
    ;;
esac
case "$prompt" in
  *"ROUTINE_RESULT"*"outcome=ok detail=idle=filed slug=<slug> result=filed-card"*) ;;
  *)
    echo "expected kanban-pickup idle fallback to emit filed-card ROUTINE_RESULT" >&2
    exit 1
    ;;
esac
case "$prompt" in
  *"file one card or work one pre-existing card, never both"*) ;;
  *)
    echo "expected kanban-pickup idle hard rule to forbid file+work in one run" >&2
    exit 1
    ;;
esac
case "$prompt" in
  *"then EXIT with \`ok idle=program-filed slug=...\` so the"*"next pickup fire claims it with a fresh budget"*) ;;
  *)
    echo "expected kanban-pickup program idle path to file and exit" >&2
    exit 1
    ;;
esac
case "$prompt" in
  *"Live operational proof watches are bounded too"*"reason=watch-budget-reserved"*) ;;
  *)
    echo "expected kanban-pickup operational watches to reserve closeout budget" >&2
    exit 1
    ;;
esac
case "$prompt" in
  *"pre-claim active Situation / harness fence for Codex usage-limit"*"noop rate-limit ... no_card_claimed"*) ;;
  *)
    echo "expected kanban-pickup to classify pre-claim harness rate-limit fences as noop" >&2
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

north_star_prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" north-star-rollup)"
case "$north_star_prompt" in
  *"reason=dashboard-timeout-prior-snapshot"*"ROUTINE_RESULT"*"outcome=<ok|noop|error> detail=<same-one-line-outcome>"*) ;;
  *)
    echo "expected north-star-rollup prompt to classify prior-snapshot dashboard timeouts as noop and emit a ROUTINE_RESULT final trailer" >&2
    exit 1
    ;;
esac

merge_babysit_prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" merge-babysit)"
if ! grep -Fq "transient shared backpressure" <<<"$merge_babysit_prompt" ||
   ! grep -Fq "busy-node/backend-unreachable" <<<"$merge_babysit_prompt"; then
  echo "expected merge-babysit to classify backend inventory outages as noop backpressure" >&2
  exit 1
fi
if ! grep -Fq "Use \`noop\` when" <<<"$merge_babysit_prompt" ||
   ! grep -Fq "first shared backend/inventory read is" <<<"$merge_babysit_prompt"; then
  echo "expected merge-babysit heartbeat contract to keep backend-unreachable out of error" >&2
  exit 1
fi

groom_board_prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" groom-board)"
if ! grep -Fq "board-socket-unavailable skipped" <<<"$groom_board_prompt" ||
   ! grep -Fq 'groom-board`, do not run doctor/init/restart' <<<"$groom_board_prompt" ||
   ! grep -Fq 'classify the run as `noop`' <<<"$groom_board_prompt" ||
   ! grep -Fq 'not `error`' <<<"$groom_board_prompt"; then
  echo "expected groom-board to classify unavailable board sockets as noop skips" >&2
  exit 1
fi
if ! grep -Fq "never read a" <<<"$groom_board_prompt" ||
   ! grep -Fq '`review` column because it does not exist' <<<"$groom_board_prompt"; then
  echo "expected groom-board snapshot instructions to avoid the retired review column" >&2
  exit 1
fi

north_star_prompt="$(LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK=1 "$ROOT/bin/last-stack-routine-read" north-star-rollup)"
if ! grep -Fq 'timeout 300 "$dash_bin"' <<<"$north_star_prompt" ||
   ! grep -Fq "reason=dashboard-timeout-prior-snapshot" <<<"$north_star_prompt"; then
  echo "expected north-star-rollup to budget dashboard refresh and soft-noop intact snapshot timeouts" >&2
  exit 1
fi
if ! grep -Fq "Dashboard timeout with a usable prior brain record + HTML snapshot" <<<"$north_star_prompt"; then
  echo "expected north-star-rollup exit semantics to keep transient dashboard timeouts out of error" >&2
  exit 1
fi
if ! grep -Fq 's/^\*\*Generated:\*\*[[:space:]]*`\([^`]*\)`.*/\1/p' <<<"$north_star_prompt"; then
  echo "expected north-star-rollup to parse markdown **Generated:** dashboard stamps" >&2
  exit 1
fi

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
