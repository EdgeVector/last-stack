#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-io-free-commit-and-barrierless-purge
# Validate the proof that Fold produced on an isolated real-data copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=harness/north-star/common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-io-free-commit-and-barrierless-purge
MODE="$(ns_mode)"
EVIDENCE="${IO_FREE_COMMIT_PROOF_EVIDENCE_FILE:-$(ns_proof_dir)/$SLUG.md}"
notes=()
failed=0

pass_note() { notes+=("$1: PASS"); }
fail_note() { notes+=("$1: FAIL"); failed=1; }

if [ ! -f "$EVIDENCE" ]; then
  fail_note "Fold terminal evidence exists at $EVIDENCE"
else
  verdict="$(sed -n '1p' "$EVIDENCE")"
  if [ "$MODE" = live ]; then
    if [ "$verdict" = PASS ]; then
      pass_note "live cutover verdict is PASS"
    else
      fail_note "live mode requires PASS, found ${verdict:-empty}"
    fi
  else
    case "$verdict" in
      PASS|PASS-OFFLINE) pass_note "isolated proof verdict is $verdict" ;;
      *) fail_note "offline mode requires PASS-OFFLINE or PASS, found ${verdict:-empty}" ;;
    esac
  fi

  p99="$(sed -n 's/^- Warm apply-gate p99: \([0-9][0-9]*\) microseconds.*$/\1/p' "$EVIDENCE" | head -1)"
  false_zero="$(sed -n 's/^- Reverse-index false-zero atoms: \([0-9][0-9]*\).*$/\1/p' "$EVIDENCE" | head -1)"
  barriers="$(sed -n 's/^- Purge schema-barrier acquisitions: \([0-9][0-9]*\).*$/\1/p' "$EVIDENCE" | head -1)"
  fixture="$(sed -n 's/^- Fixture: //p' "$EVIDENCE" | head -1)"

  if [ -n "$p99" ] && [ "$p99" -lt 5000 ]; then
    pass_note "warm apply-gate p99 is ${p99} microseconds (<5000)"
  else
    fail_note "warm apply-gate p99 is ${p99:-missing} microseconds"
  fi
  if [ "$false_zero" = 0 ]; then
    pass_note "reverse-index false-zero atoms are 0"
  else
    fail_note "reverse-index false-zero atoms are ${false_zero:-missing}"
  fi
  if [ "$barriers" = 0 ]; then
    pass_note "purge schema-barrier acquisitions are 0"
  else
    fail_note "purge schema-barrier acquisitions are ${barriers:-missing}"
  fi
  case "$fixture" in
    *isolated*copy*cloud\ sync\ disabled*) pass_note "fixture is an isolated copy with cloud sync disabled" ;;
    *) fail_note "fixture safety statement is missing or incomplete" ;;
  esac
fi

body=""
for note in "${notes[@]}"; do
  body="${body}- ${note}"$'\n'
done
body="${body}"$'\n'"Evidence file: \`$EVIDENCE\`. This harness validates Fold output only; it never opens a LastDB home or socket."
if [ "$failed" -eq 0 ]; then
  if [ "$MODE" = live ]; then
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
else
  ns_write_report "$SLUG" FAIL "$body"
fi
