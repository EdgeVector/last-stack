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

# Capture everything; run.sh prints VERDICT on stderr and optional JSON on stdout.
TMP="$(mktemp -t llms-txt-routine-run.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

set +e
bash "$RUN_SH" --json >"$TMP.stdout" 2>"$TMP.stderr"
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
  echo "routine-run.sh: incomplete smoke — no VERDICT line (exit was $EC)" >&2
  echo "RESULT: error RED incomplete-no-verdict exit=$EC"
  exit 2
fi

if echo "$VERDICT_LINE" | grep -q 'GREEN'; then
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
echo "RESULT: error RED ${FAIL_LINE:-verdict=RED} exit=$EC"
# Normalize RED to exit 1 even if run.sh used another non-zero.
exit 1
