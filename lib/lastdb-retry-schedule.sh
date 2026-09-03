#!/usr/bin/env bash
# Shared drain-aware retry schedule for LastDB persist_queue_full / flap waits.
# Source this file; do not execute it directly.
#
# Defaults: 5 attempts, sleeps 15s, 45s, 90s, 120s between them (last value
# repeats if the caller asks for more attempts). A 10 s fixed sleep never
# reaches a 45 s drain.
#
# Environment:
#   LAST_STACK_LASTDB_RETRY_ATTEMPTS       default attempt count (5)
#   LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC   comma list, default 15,45,90,120
#   LAST_STACK_LASTDB_RETRY_SLEEP_SEC      if set, fixed sleep instead of list
#   LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH unix seconds; cap each wait

last_stack_lastdb_retry_default_attempts() {
  local n="${LAST_STACK_LASTDB_RETRY_ATTEMPTS:-5}"
  case "$n" in
    ''|*[!0-9]*) n=5 ;;
  esac
  [ "$n" -ge 1 ] || n=5
  printf '%s\n' "$n"
}

# Sleep seconds after attempt $1 (1-based) before the next try.
last_stack_lastdb_retry_sleep_sec() {
  local attempt="${1:-1}"
  local fixed="${LAST_STACK_LASTDB_RETRY_SLEEP_SEC:-}"
  if [ -n "$fixed" ]; then
    case "$fixed" in
      ''|*[!0-9]*) fixed=15 ;;
    esac
    printf '%s\n' "$fixed"
    return 0
  fi
  local sched="${LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC:-15,45,90,120}"
  local oldifs="$IFS"
  local noglob=0
  local val=""
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  IFS=,
  # shellcheck disable=SC2086
  set -- $sched
  IFS="$oldifs"
  [ "$noglob" -eq 1 ] || set +f
  case "$attempt" in
    ''|*[!0-9]*) attempt=1 ;;
  esac
  [ "$attempt" -ge 1 ] || attempt=1
  if [ "$#" -lt 1 ]; then
    printf '15\n'
    return 0
  fi
  if [ "$attempt" -le "$#" ]; then
    eval "val=\${$attempt}"
  else
    eval "val=\${$#}"
  fi
  case "$val" in
    ''|*[!0-9]*) val=15 ;;
  esac
  printf '%s\n' "$val"
}

# Cap a requested sleep so the next attempt still has one second of budget.
last_stack_lastdb_retry_capped_sleep_sec() {
  local want="${1:-0}"
  local deadline="${LAST_STACK_LASTDB_RETRY_DEADLINE_EPOCH:-}"
  case "$want" in
    ''|*[!0-9]*) want=0 ;;
  esac
  if [ -z "$deadline" ]; then
    printf '%s\n' "$want"
    return 0
  fi
  case "$deadline" in
    ''|*[!0-9]*) printf '%s\n' "$want"; return 0 ;;
  esac
  local now remaining cap
  now="$(date -u +%s)"
  remaining=$((deadline - now))
  if [ "$remaining" -le 1 ]; then
    printf '0\n'
    return 0
  fi
  cap=$((remaining - 1))
  if [ "$want" -gt "$cap" ]; then
    printf '%s\n' "$cap"
  else
    printf '%s\n' "$want"
  fi
}

last_stack_lastdb_retry_wait() {
  local sec="${1:-0}"
  case "$sec" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$sec" -gt 0 ] || return 0
  sleep "$sec"
}

# One-token reason for the wait log. Keep it short and non-secret.
last_stack_lastdb_retry_reason() {
  local text="${1:-}"
  if printf '%s' "$text" | grep -Eiq 'persist_queue_full|persist queue full'; then
    printf 'persist_queue_full\n'
  elif printf '%s' "$text" | grep -Eiq 'capture queue remained full'; then
    printf 'capture_queue_full\n'
  elif printf '%s' "$text" | grep -Eiq 'retry after drain'; then
    printf 'retry_after_drain\n'
  elif printf '%s' "$text" | grep -Eiq 'service_timeout'; then
    printf 'service_timeout\n'
  elif printf '%s' "$text" | grep -Eiq 'too many concurrent reads'; then
    printf 'concurrent_reads\n'
  else
    printf 'transient_flap\n'
  fi
}
