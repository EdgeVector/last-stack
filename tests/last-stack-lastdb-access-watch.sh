#!/usr/bin/env bash
# Tests for last-stack-lastdb-access-watch.
#
# The load-bearing assertion is the MALFORMED case: a detector that cannot parse
# its input must exit non-zero, never "clean". A silent no-match would make a
# broken watcher indistinguishable from a healthy system — the exact failure
# this whole gate family exists to prevent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-access-watch"
FIX="$ROOT/tests/fixtures/lastdb-access-watch"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- clean sample: every read is keyed (~1 load/call) ------------------------
out="$("$BIN" --ops-file "$FIX/clean.txt" 2>&1)" || fail "clean sample should exit 0, got $?"
case "$out" in
  ok\ last-stack-lastdb-access-watch*) : ;;
  *) fail "clean sample should report ok, got: $out" ;;
esac

# A mutation touching 90 shards/call must NOT be flagged — writes legitimately
# touch many shards, and flagging them would bury the read signal.
case "$out" in
  *cccc3333*) fail "clean sample flagged a mutation; reads only" ;;
esac

# --- offender sample ---------------------------------------------------------
set +e
out="$("$BIN" --ops-file "$FIX/offender.txt" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "offender sample should exit 1, got $rc"
case "$out" in
  *sweeper*) : ;;
  *) fail "default (ring) should flag the ring-window sweeper" ;;
esac
# The lifetime row is NOT a finding under the default window, but must still be
# surfaced as an advisory NOTE rather than vanishing.
case "$out" in
  *"NOTE"*39a04240*) : ;;
  *) fail "lifetime row should appear as a dilution NOTE under --window ring" ;;
esac

# --- DILUTION: the whole reason the default window changed --------------------
# Ring is clean; lifetime holds a persistent offender that walked itself under
# the threshold (26 -> 6 loads/call purely as count grew 175 -> 730).
set +e
out="$("$BIN" --ops-file "$FIX/diluted.txt" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "diluted sample: ring is clean, should exit 0, got $rc"
case "$out" in
  *"NOTE"*39a04240*) : ;;
  *) fail "diluted offender must still surface as a NOTE on a clean ring run" ;;
esac
# A clean run must not imply absence.
case "$out" in
  *"not 'nothing wrong'"*) : ;;
  *) fail "clean ring output must state what clean does NOT mean" ;;
esac
# ...and --window lifetime must still catch it when asked.
set +e
out="$("$BIN" --ops-file "$FIX/diluted.txt" --window lifetime --threshold 5 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "--window lifetime --threshold 5 should catch the diluted row, got $rc"
case "$out" in
  *39a04240*) : ;;
  *) fail "--window lifetime should name the diluted schema" ;;
esac

# --- COLLAPSED metric: loads/call is useless here, avg_ms is not -------------
# Real shape observed 2026-08-08: the offender's loads/call fell to 2 (integer
# average, collapsing as count grew) while its TOTAL time rose to 421s. A
# per-call-only rule misses it entirely. This is the regression guard for that.
set +e
out="$("$BIN" --ops-file "$FIX/collapsed.txt" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "collapsed sample: ring clean, should exit 0, got $rc"
case "$out" in
  *"NOTE"*39a04240*) : ;;
  *) fail "collapsed offender must be caught by the avg_ms trigger despite loads/call=2" ;;
esac
# ...and a healthy HIGH-VOLUME cheap read must NOT be dragged in with it,
# or the advisory becomes noise and gets ignored.
case "$out" in
  *aaaa1111*) fail "10487-call read averaging 2.5ms must not be flagged" ;;
esac

# --- window validation -------------------------------------------------------
set +e
"$BIN" --ops-file "$FIX/clean.txt" --window bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --window must exit 2, got $rc"

# --- report content (own run; do not inherit $out from a block above) --------
set +e
report_out="$("$BIN" --ops-file "$FIX/offender.txt" 2>&1)"
set -e

# count<5 is a cold-start artefact, not a pattern: the 1533-loads/call single
# call must be ignored, or every daemon restart produces a fake finding.
case "$report_out" in
  *eeee5555*) fail "single-call cold read should not be flagged" ;;
esac

# The report must say what to do, not just what is wrong.
case "$report_out" in
  *concepts-lastdb-agent-access-model*) : ;;
  *) fail "report should name the access-model record to consult" ;;
esac
# ...and must not invite the destructive non-fix.
case "$report_out" in
  *"Do NOT reindex or restart"*) : ;;
  *) fail "report must warn against reindex/restart as a response" ;;
esac

# --- threshold is honored ----------------------------------------------------
out="$("$BIN" --ops-file "$FIX/offender.txt" --threshold 100 2>&1)" \
  || fail "threshold 100 should clear the 26-loads/call offender"
case "$out" in
  ok\ *) : ;;
  *) fail "threshold 100 should report ok, got: $out" ;;
esac

# --- MALFORMED: must be UNKNOWN (exit 2), never clean ------------------------
set +e
out="$("$BIN" --ops-file "$FIX/malformed.txt" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "malformed sample must exit 2 (unknown), got $rc"
case "$out" in
  ok\ *) fail "malformed sample reported CLEAN — this is the false green the detector exists to avoid" ;;
esac
case "$out" in
  *"Refusing to report clean"*) : ;;
  *) fail "malformed sample should say why it refused, got: $out" ;;
esac

# --- missing file also unknown, not clean ------------------------------------
set +e
"$BIN" --ops-file "$FIX/does-not-exist.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing ops file must exit 2, got $rc"

# --- json shape --------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  set +e
  json="$("$BIN" --ops-file "$FIX/offender.txt" --json 2>/dev/null)"
  set -e
  n="$(printf '%s' "$json" | jq -r '.finding_count')"
  [ "$n" = "1" ] || fail "json finding_count should be 1 under the ring default, got $n"
  [ "$(printf '%s' "$json" | jq -r '.window')" = "ring" ] \
    || fail "json should report the window it alerted on"
  [ "$(printf '%s' "$json" | jq -r '.findings[0].window')" = "ring" ] \
    || fail "the ring default must not emit lifetime rows as findings"
  # The dilution advisory must be machine-readable too — a consumer that only
  # reads finding_count would otherwise re-acquire the blind spot.
  [ "$(printf '%s' "$json" | jq -r '.dilution_notes | length')" = "1" ] \
    || fail "json should carry the lifetime dilution note"
  [ "$(printf '%s' "$json" | jq -r '.dilution_notes[0].schema')" = "39a04240" ] \
    || fail "dilution note should name the diluted schema"
fi

echo "ok last-stack-lastdb-access-watch"
