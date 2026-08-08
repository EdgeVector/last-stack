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
  *39a04240*) : ;;
  *) fail "offender sample should name the kanban schema, got: $out" ;;
esac
case "$out" in
  *sweeper*) : ;;
  *) fail "offender sample should also flag the ring-window sweeper" ;;
esac

# count<5 is a cold-start artefact, not a pattern: the 1533-loads/call single
# call must be ignored, or every daemon restart produces a fake finding.
case "$out" in
  *eeee5555*) fail "single-call cold read should not be flagged" ;;
esac

# The report must say what to do, not just what is wrong.
case "$out" in
  *concepts-lastdb-agent-access-model*) : ;;
  *) fail "report should name the access-model record to consult" ;;
esac
# ...and must not invite the destructive non-fix.
case "$out" in
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
  [ "$n" = "2" ] || fail "json finding_count should be 2, got $n"
  top="$(printf '%s' "$json" | jq -r '.findings[0].loads_per_call')"
  [ "$top" = "1533" ] || [ "$top" = "30" ] || [ "$top" = "26" ] \
    || fail "json findings should be sorted by loads_per_call desc, top=$top"
fi

echo "ok last-stack-lastdb-access-watch"
