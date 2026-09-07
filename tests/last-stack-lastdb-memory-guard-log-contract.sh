#!/usr/bin/env bash
# last-stack-lastdb-memory-guard log field contract.
#
# The guard's telemetry lines are unversioned space-separated key=value text.
# On 2026-09-04 the rusage reader port dropped `peak_mb` from the `ok` line and
# the field stayed absent for 2.8 days and 3248 lines with nothing saying a
# field had gone — peak_mb being the only field that can show an excursion the
# 60 s sampler missed. The contract exists so that loss fails loudly, and these
# are its tests.
#
# Two halves, and both matter:
#   - the pure checker (log_contract_missing) is exercised directly, extracted
#     from the shipped script between its own markers so there is exactly one
#     declaration of the required key set
#   - `--check-log-contract` is exercised against fixture logs, including the
#     shape of the real regression: one field, present before and after, absent
#     in a window
# plus a structural assertion that the three telemetry sites actually route
# through the checker, because a contract nothing calls is not a contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUARD="$ROOT/bin/last-stack-lastdb-memory-guard"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

COMPLETE='2026-09-07T12:14:00Z ok pid=40502 metric=footprint enforced_mb=13007 limit_mb=16384 rss_mb=1259 footprint_mb=13007 peak_mb=17791 footprint_source=rusage swap_mb=17212'

# --- the pure checker, extracted from the one place the keys are declared ----
sed -n '/^# >>> log field contract/,/^# <<< log field contract/p' "$GUARD" >"$tmp/contract.sh"
grep -q 'log_contract_keys()' "$tmp/contract.sh" \
  || fail "contract markers in $GUARD no longer bracket log_contract_keys"
# shellcheck disable=SC1090
. "$tmp/contract.sh"

got="$(log_contract_missing ok "$COMPLETE")"
[ -z "$got" ] || fail "a complete ok line reported missing keys: $got"

# A dropped field. This is the 2026-09-04 line, verbatim in shape.
dropped='2026-09-04T11:28:35Z ok pid=12849 metric=footprint enforced_mb=9107 limit_mb=16384 rss_mb=5194 footprint_mb=9107 footprint_source=rusage swap_mb=6853'
got="$(log_contract_missing ok "$dropped")"
[ "$got" = "peak_mb" ] || fail "expected missing=peak_mb, got '$got'"

# An unset shell variable interpolates as an empty value, not an absent key.
# That is a distinct shape and it has to fail too.
empty="${COMPLETE/peak_mb=17791/peak_mb=}"
got="$(log_contract_missing ok "$empty")"
[ "$got" = "peak_mb=empty" ] || fail "expected missing=peak_mb=empty, got '$got'"

# `pid=` must not be satisfied by `new_pid=`; the leading space is what does it.
got="$(log_contract_missing ok '2026-09-07T00:00:00Z ok new_pid=1 metric=footprint enforced_mb=1 limit_mb=2 rss_mb=1 footprint_mb=1 peak_mb=1 footprint_source=rusage swap_mb=1')"
[ "$got" = "pid" ] || fail "new_pid= wrongly satisfied the pid key: got '$got'"

# An event with no declared contract is not policed.
got="$(log_contract_missing shed_ok 'shed_ok socket=/tmp/x')"
[ -z "$got" ] || fail "an uncontracted event reported missing keys: $got"

# --- the scanner, against fixture logs ---------------------------------------
scan() { bash "$GUARD" --check-log-contract "$@"; }

clean="$tmp/clean.log"
printf '%s\n' "$COMPLETE" >"$clean"
# Lines that carry no contract must be skipped, not counted as violations.
printf '%s\n' '2026-09-07T12:15:00Z ok no_primary_lastdbd revive=disabled' >>"$clean"
printf '%s\n' '2026-09-07T12:16:00Z shed_ok socket=/tmp/x' >>"$clean"
out="$(scan "$clean")" || fail "clean fixture failed the scan: $out"
case "$out" in
  *"checked=1 violations=0"*) ;;
  *) fail "clean fixture: expected checked=1 violations=0, got: $out" ;;
esac

# The real regression shape: present, absent for a window, present again.
window="$tmp/window.log"
{
  printf '%s\n' '2026-09-04T11:27:12Z ok pid=12849 metric=footprint enforced_mb=8911 limit_mb=16384 rss_mb=4626 footprint_mb=8911 peak_mb=15495 footprint_source=rusage swap_mb=6853'
  printf '%s\n' "$dropped"
  printf '%s\n' '2026-09-05T00:00:00Z ok pid=12849 metric=footprint enforced_mb=9000 limit_mb=16384 rss_mb=5000 footprint_mb=9000 footprint_source=rusage swap_mb=6000'
  printf '%s\n' '2026-09-05T00:14:52Z OVER_LIMIT pid=12849 metric=footprint enforced_mb=17000 limit_mb=16384 rss_mb=5000 footprint_mb=17000 footprint_source=rusage swap_mb=6000 cmd=lastdbd'
  printf '%s\n' "$COMPLETE"
} >"$window"

if out="$(scan "$window")"; then
  fail "a log with a dropped field exited 0: $out"
fi
case "$out" in
  *"violations=2      event+missing=ok peak_mb first=2026-09-04T11:28:35Z last=2026-09-05T00:00:00Z"*) ;;
  *) fail "expected a grouped ok/peak_mb row with first and last, got: $out" ;;
esac
case "$out" in
  *"event+missing=OVER_LIMIT peak_mb "*) ;;
  *) fail "OVER_LIMIT lines are contracted too; no row for them: $out" ;;
esac
case "$out" in
  *"checked=5 violations=3"*) ;;
  *) fail "expected checked=5 violations=3, got: $out" ;;
esac

# --since bounds the scan, which is how an operator asks whether the CURRENT
# format is whole without being told about every deliberate past format change.
out="$(scan "$window" --since 2026-09-07)" || fail "bounded clean window exited non-zero: $out"
case "$out" in
  *"since=2026-09-07 checked=1 violations=0"*) ;;
  *) fail "--since did not bound the scan: $out" ;;
esac
out="$(scan "$window" --since=2026-09-07)" || fail "--since=VALUE form failed: $out"

# An unreadable log is an error, not a pass.
if scan "$tmp/does-not-exist.log" >/dev/null 2>&1; then
  fail "a missing log file scanned successfully"
fi

# --- the call sites actually route through the checker -----------------------
for event in ok over_limit_candidate OVER_LIMIT; do
  grep -q "^log_checked $event \"$event " "$GUARD" \
    || fail "the $event telemetry line does not go through log_checked"
done

printf 'PASS: last-stack-lastdb-memory-guard log field contract\n'
