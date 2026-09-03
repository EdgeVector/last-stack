#!/usr/bin/env bash
# Per-definition loom drive deadline for last-stack launchers.
# Empty output means leave LOOM_RUN_DEADLINE_SECS unset (loom default 300s).
#
# lastdb-safe-upgrade CUTOVER clones a multi-GiB home (~25 min) plus probe.
# The loom run drive default (300s) kills that step with no recorded result.
# lastdb-canary-release CALL_A's that child, so it uses the same budget.

loom_run_deadline_secs() {
  case "${1:-}" in
    lastdb-safe-upgrade|lastdb-canary-release)
      printf '%s\n' "${LAST_STACK_SAFE_UPGRADE_LOOM_DEADLINE_SECS:-5400}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

# Raise LOOM_RUN_DEADLINE_SECS to the definition's floor. Never shrink an
# already-larger explicit value (the 2026-09-03 manual 5400 workaround).
export_loom_run_deadline_for() {
  local wanted current
  wanted="$(loom_run_deadline_secs "$1")"
  [ -n "$wanted" ] || return 0
  current="${LOOM_RUN_DEADLINE_SECS:-0}"
  case "$current" in
    ''|*[!0-9]*) current=0 ;;
  esac
  if [ "$current" -lt "$wanted" ]; then
    export LOOM_RUN_DEADLINE_SECS="$wanted"
  fi
}
