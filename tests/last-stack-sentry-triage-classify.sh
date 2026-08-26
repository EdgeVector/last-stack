#!/usr/bin/env bash
# Regression cover for last-stack-sentry-triage-classify, the executable form of
# the sentry-triage Step 2 / Step 3 policy.
#
# Card: sentry-triage-drop-sample-events-and-fix-unreachable-p3-rule.
# Two defects lived in the prompt as prose and produced a bad card:
#   1. no sample-event exclusion, so Sentry's seeded sample event was triaged;
#   2. the P1 branch tested `userCount >= 1` first, which is true for nearly
#      every real issue, so the P3 single/stale suppression under it was
#      UNREACHABLE.
#
# Every suppression assertion below is paired with a vacuity companion: the
# sibling that must still FILE in the same run. A drop test without a companion
# passes when the filter has swallowed everything.
#
# Issue fixtures are trimmed captures of the three real Sentry issues named in
# the card evidence, measured 2026-08-26. The clock is pinned with --now so the
# staleness assertions do not rot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-sentry-triage-classify"
fx="$ROOT/tests/fixtures/sentry-triage"
prompt="$ROOT/routines/sentry-triage.md"
NOW="2026-08-26T01:00:00Z"

[ -x "$bin" ] || { echo "FAIL: $bin is not executable"; exit 1; }

fails=0

# assert <label> <expected-verdict> <issue-fixture> [event-fixture]
assert() {
  local label="$1" want="$2" issue="$3" event="${4:-}"
  local got
  if [ -n "$event" ]; then
    got="$("$bin" --issue "$fx/$issue" --latest-event "$fx/$event" --now "$NOW" | awk '{print $1}')"
  else
    got="$("$bin" --issue "$fx/$issue" --now "$NOW" | awk '{print $1}')"
  fi
  if [ "$got" = "$want" ]; then
    echo "ok   $label -> $got"
  else
    echo "FAIL $label -> got '$got', want '$want'"
    fails=$((fails + 1))
  fi
}

echo "== Defect 1: Sentry sample events are dropped at Step 2 =="
# Issue 7535210070: Sentry's seeded sample event. It matches NONE of the legacy
# title markers, so only the sample_event tag catches it.
assert "sample-event tag drops the issue" drop \
  issue-7535210070.json event-7535210070.json

# Companion 1: the exact same issue body without the event. It must survive the
# tag test and reach Step 3, proving the drop came from the tag and the filter
# is not swallowing everything. It is single + 80d stale, so Step 3 suppresses.
assert "same issue, no event: not dropped by tag" P3 issue-7535210070.json

# Companion 2: the two real siblings carry no sample_event tag and must survive.
assert "real rust issue survives Step 2" P1 \
  issue-7671016505.json event-7671016505.json
assert "real react issue survives Step 2" P2 \
  issue-7605584694.json event-7605584694.json

echo "== Defect 2: the single/stale suppression is REACHABLE =="
# The card's VERIFY case: single occurrence, 90 days stale, userCount=1, error.
# Under the old ladder `userCount >= 1` made this P1. It must not file now.
assert "single + 90d stale is suppressed" P3 issue-synthetic-stale-single.json

# Vacuity companion A: same shape, but only 46 days stale (the real issue
# 7605584694). It is under the 60-day bar, so it must still FILE.
assert "single + 46d stale still files" P2 \
  issue-7605584694.json event-7605584694.json

# Vacuity companion B: the crash / data-loss escape hatch still files even when
# single and 90d stale.
assert "single + stale + data-loss still files" P2 \
  issue-synthetic-stale-single-crash.json

# Vacuity companion C: high volume is never suppressed.
assert "high-volume issue is P1" P1 \
  issue-7671016505.json event-7671016505.json

echo "== The tautology must not come back =="
# `userCount >= 1` as a P1 clause is the defect itself. Every fixture here has
# userCount <= 1, so if the clause returns, the stale single becomes P1 and the
# assertion above flips. Pin the source too, so a prose edit cannot reintroduce
# it silently.
# Match the CODE (snake_case `user_count`), not the docstring that documents the
# defect in Sentry's camelCase field name. Grepping the prose form fails on the
# very comment that explains why the clause is banned.
if grep -qE 'user_count >= 1[^0-9]' "$bin"; then
  echo "FAIL classifier hardcodes the tautological 'user_count >= 1' P1 clause"
  fails=$((fails + 1))
else
  echo "ok   classifier has no hardcoded 'user_count >= 1' P1 clause"
fi

# The threshold constant is the real guard: at 1 it is a tautology again.
p1_users="$(sed -n 's/^P1_USER_COUNT = \([0-9][0-9]*\)$/\1/p' "$bin")"
if [ -n "$p1_users" ] && [ "$p1_users" -ge 2 ]; then
  echo "ok   P1_USER_COUNT is a real threshold ($p1_users)"
else
  echo "FAIL P1_USER_COUNT must be >= 2, got '${p1_users:-unset}'"
  fails=$((fails + 1))
fi

echo "== The prompt and the classifier agree =="
for needle in 'sample_event' 'last-stack-sentry-triage-classify'; do
  if grep -q "$needle" "$prompt"; then
    echo "ok   prompt mentions $needle"
  else
    echo "FAIL prompt is missing $needle"
    fails=$((fails + 1))
  fi
done

# The prompt must state the ordering, not just the rules: Step 3 is only correct
# when the suppression rule is evaluated before the P1 rule.
if grep -qi 'BEFORE the `P1` rule' "$prompt"; then
  echo "ok   prompt states suppression runs before P1"
else
  echo "FAIL prompt does not state the suppression/P1 ordering"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails assertion(s)"
  exit 1
fi
echo "PASS: last-stack-sentry-triage-classify"
