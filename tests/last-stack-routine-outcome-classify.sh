#!/usr/bin/env bash
# Drive the shipped classifier on synthetic observer findings + a real
# routines-status fixture. No LastDB or kanban I/O.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-routine-outcome-classify"
fixture="$ROOT/tests/fixtures/routine-outcome-classify/status-red-observers.json"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || fail "classifier missing or not executable"

got="$("$bin" --observer last-stack-pipeline-health --exit 0 --detail 'open_cr=2 stuck=fold:1570:red')"
[ "$got" = "ok" ] || fail "pipeline-health downstream red should be ok, got $got"

got="$("$bin" --observer last-stack-why-stopped --exit 0 --detail 'classes=unknown')"
[ "$got" = "ok" ] || fail "why-stopped classes=unknown should be ok, got $got"

got="$("$bin" --observer last-stack-whats-wrong --exit 0 --detail 'exceptions=2 remaining=1')"
[ "$got" = "ok" ] || fail "whats-wrong remaining red should be ok, got $got"

got="$("$bin" --observer last-stack-whats-wrong --exit 0 --detail 'exceptions=0')"
[ "$got" = "noop" ] || fail "whats-wrong empty list should be noop, got $got"

got="$("$bin" --observer last-stack-ship-pipeline-gap-audit --exit 0 --detail 'health=yellow gaps=3 filed=1')"
[ "$got" = "ok" ] || fail "ship-pipeline yellow should be ok, got $got"

got="$("$bin" --observer routine-fleet-health --exit 0 --detail 'busy-node status-timeout')"
[ "$got" = "noop" ] || fail "fleet-health busy-node should be noop, got $got"

got="$("$bin" --observer last-stack-pipeline-health --exit 124 --detail 'timed out' --timed-out 1)"
[ "$got" = "error" ] || fail "observer timeout should stay error, got $got"

got="$("$bin" --observer last-stack-why-stopped --exit 1 --detail 'CLI missing')"
[ "$got" = "error" ] || fail "missing CLI should stay error, got $got"

# Trailer emission uses the placeholder-safe ROUTINE_RESULT token.
trailer="$("$bin" --observer last-stack-pipeline-health --exit 0 --detail 'stuck=red_ci' --emit-result | tail -1)"
case "$trailer" in
  "ROUTINE_RESULT outcome=ok detail=stuck=red_ci") ;;
  *) fail "emit-result trailer: $trailer" ;;
esac

[ -f "$fixture" ] || fail "missing fixture $fixture"
summary="$("$bin" --status-json "$fixture")"
printf '%s\n' "$summary" | grep -q 'relabel_ids=' || fail "fixture should relabel observers: $summary"
printf '%s\n' "$summary" | grep -q 'last-stack-pipeline-health' || fail "expected pipeline-health in relabel set: $summary"
printf '%s\n' "$summary" | grep -q 'last-stack-why-stopped' || fail "expected why-stopped in relabel set: $summary"
printf '%s\n' "$summary" | grep -q 'last-stack-ship-pipeline-gap-audit' || fail "expected ship-pipeline in relabel set: $summary"

# True reds (timeouts / job failures) must remain red in the fixture.
printf '%s\n' "$summary" | grep -q 'lastdb-local-smoke-test' || fail "smoke timeout must stay true-red: $summary"
printf '%s\n' "$summary" | grep -q 'dogfood-rotate' || fail "dogfood-rotate fail must stay true-red: $summary"

# JSON mode is what fleet-health gate consumes.
json="$("$bin" --status-json "$fixture" --json)"
printf '%s\n' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "true_reds" in d and "relabeled" in d, d
assert d["relabeled"] >= 3, d
relabel=set(d["relabel_ids"])
for name in ("last-stack-pipeline-health","last-stack-why-stopped","last-stack-ship-pipeline-gap-audit"):
    assert name in relabel, (name, relabel)
assert "lastdb-local-smoke-test" in d["red_ids"], d["red_ids"]
'

echo "ok"
