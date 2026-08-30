#!/usr/bin/env bash
# Mechanical entrypoint for the scheduled llms-txt-install-smoke routine.
# Forces a real foreground smoke, refuses to report success without VERDICT,
# and prints a RESULT: trailer for the routines outcome parser.
#
# Exit codes:
#   0 — VERDICT: GREEN from run.sh
#   1 — VERDICT: RED from run.sh
#   2 — incomplete (no VERDICT line; killed/truncated/miswired)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="${SKILL_DIR}/run.sh"
if [ ! -f "$RUN_SH" ]; then
  echo "routine-run.sh: missing run.sh next to this wrapper: $RUN_SH" >&2
  echo "RESULT: error RED incomplete-missing-run-sh"
  exit 2
fi

# run.sh carries its own global deadline, but that deadline only clamps calls
# routed through run_bounded. Anything it does not wrap — a new step, a network
# pipeline, a wedged child — can still hang the whole run past the foreground
# cap, which is how the 2026-08-29 run died mute with no VERDICT line and was
# reconciled as an orphan. This outer bound is the backstop: whatever run.sh
# does, the wrapper reaches its RESULT trailer. It must sit ABOVE run.sh's own
# budget (540s) so the internal deadline stays the primary mechanism, and below
# the 600s foreground cap so the trailer is still printed.
# shellcheck source=lib-bounded.sh
. "${SKILL_DIR}/lib-bounded.sh"
SMOKE_WRAPPER_TIMEOUT_SECS="${SMOKE_WRAPPER_TIMEOUT_SECS:-570}"

# Capture everything; run.sh prints VERDICT on stderr and optional JSON on stdout.
# Use an explicit ${TMPDIR:-/tmp} template. Darwin prefix-only mktemp selects
# /var/folders/... which the Codex/routine sandbox denies
# (papercut-last-stack-ci-bare-mktemp-denied-in-codex-sandbox).
TMP="$(mktemp "${TMPDIR:-/tmp}/llms-txt-routine-run.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if [ -n "${ROUTINES_RUN_DIR:-}" ]; then
  FAILURE_LOG="$ROUTINES_RUN_DIR/smoke-run.log"
else
  FAILURE_LOG="$TMP.run.log"
fi

set +e
# Exported, not an assignment prefix: run_bounded is a shell function, so a
# prefix would not reach the child.
export LLMS_TXT_SMOKE_FAILURE_LOG="$FAILURE_LOG"
run_bounded "$SMOKE_WRAPPER_TIMEOUT_SECS" bash "$RUN_SH" --json \
  >"$TMP.stdout" 2>"$TMP.stderr"
EC=$?
set -e

cat "$TMP.stderr" >&2
if [ -s "$TMP.stdout" ]; then
  cat "$TMP.stdout"
fi

VERDICT_LINE="$(
  { cat "$TMP.stderr" 2>/dev/null; cat "$TMP.stdout" 2>/dev/null; } \
    | grep -E '^VERDICT: (GREEN|RED)' | tail -n1 || true
)"

if [ -z "$VERDICT_LINE" ]; then
  # Also accept JSON-only summary if VERDICT line was lost but JSON remains.
  JSON_V="$(
    grep -E '"verdict"[[:space:]]*:[[:space:]]*"(GREEN|RED)"' "$TMP.stdout" 2>/dev/null \
      | tail -n1 || true
  )"
  if echo "$JSON_V" | grep -q '"GREEN"'; then
    VERDICT_LINE="VERDICT: GREEN"
  elif echo "$JSON_V" | grep -q '"RED"'; then
    VERDICT_LINE="VERDICT: RED"
  fi
fi

if [ -z "$VERDICT_LINE" ]; then
  if [ "$EC" -eq 124 ]; then
    # The backstop fired. Name it, so the outcome reads as a bounded hang
    # rather than an unexplained mute run.
    echo "routine-run.sh: smoke exceeded the wrapper bound of ${SMOKE_WRAPPER_TIMEOUT_SECS}s" >&2
    if [ -f "$FAILURE_LOG" ]; then
      echo "routine-run.sh: failure log preserved at $FAILURE_LOG" >&2
    fi
    echo "RESULT: error RED incomplete-timeout wrapper=${SMOKE_WRAPPER_TIMEOUT_SECS}s"
    exit 2
  fi
  echo "routine-run.sh: incomplete smoke — no VERDICT line (exit was $EC)" >&2
  echo "RESULT: error RED incomplete-no-verdict exit=$EC"
  exit 2
fi

# Anchored: the RED verdict now carries a trailing step list, so a loose
# substring match could be spoofed by a step name into a false GREEN.
if echo "$VERDICT_LINE" | grep -q '^VERDICT: GREEN'; then
  # Prefer pass counts from the script footer when present.
  PASS_LINE="$(
    { cat "$TMP.stderr" 2>/dev/null; } | grep -E '^PASS \(' | tail -n1 || true
  )"
  echo "RESULT: ok GREEN ${PASS_LINE:-verdict=GREEN}"
  exit 0
fi

FAIL_LINE="$(
  { cat "$TMP.stderr" 2>/dev/null; } | grep -E '^FAIL \(' | tail -n1 || true
)"
if [ -f "$FAILURE_LOG" ]; then
  echo "routine-run.sh: failure log preserved at $FAILURE_LOG" >&2
fi
echo "RESULT: error RED ${FAIL_LINE:-verdict=RED} exit=$EC"
# Normalize RED to exit 1 even if run.sh used another non-zero.
exit 1
