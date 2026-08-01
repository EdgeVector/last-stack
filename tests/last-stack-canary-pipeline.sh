#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$CLI"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"

out="$("$CLI" --state-dir "$state_dir" --json create cand-a --version 0.23.2 --source nightly)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "candidate_found" ]
[ "$(printf '%s\n' "$out" | jq -r '.version')" = "0.23.2" ]

if "$CLI" --state-dir "$state_dir" create cand-a >/tmp/canary-dup.out 2>/tmp/canary-dup.err; then
  echo "expected duplicate create to fail" >&2
  exit 1
fi
grep -q 'candidate already exists' /tmp/canary-dup.err

"$CLI" --state-dir "$state_dir" advance cand-a dogfood_started --note dogfood >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a dogfood_green >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a soak_started >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a soak_green >/dev/null
out="$("$CLI" --state-dir "$state_dir" --json advance cand-a promote_prepare)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "promote_prepare" ]

out="$("$CLI" --state-dir "$state_dir" --json read cand-a)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "promote_prepare" ]
[ "$(wc -l <"$state_dir/ledger.jsonl" | tr -d ' ')" = "6" ]

if "$CLI" --state-dir "$state_dir" advance cand-a promote_prepare >/tmp/canary-repeat.out 2>/tmp/canary-repeat.err; then
  echo "expected duplicate transition to fail" >&2
  exit 1
fi
grep -q 'duplicate transition' /tmp/canary-repeat.err

if "$CLI" --state-dir "$state_dir" advance cand-a dogfood_started >/tmp/canary-regress.out 2>/tmp/canary-regress.err; then
  echo "expected regressing transition to fail" >&2
  exit 1
fi
grep -q 'invalid transition' /tmp/canary-regress.err

"$CLI" --state-dir "$state_dir" create cand-b >/dev/null
if "$CLI" --state-dir "$state_dir" advance cand-b soak_started >/tmp/canary-skip.out 2>/tmp/canary-skip.err; then
  echo "expected skipped transition to fail" >&2
  exit 1
fi
grep -q 'invalid transition' /tmp/canary-skip.err

"$CLI" --state-dir "$state_dir" advance cand-b dogfood_started >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-b dogfood_red >/dev/null
if "$CLI" --state-dir "$state_dir" advance cand-b soak_started >/tmp/canary-red.out 2>/tmp/canary-red.err; then
  echo "expected red terminal transition to fail" >&2
  exit 1
fi
grep -q 'allowed: none' /tmp/canary-red.err

if "$CLI" --state-dir "$state_dir" read missing >/tmp/canary-missing.out 2>/tmp/canary-missing.err; then
  echo "expected missing read to fail" >&2
  exit 1
fi
grep -q 'candidate not found' /tmp/canary-missing.err

out="$("$CLI" --state-dir "$state_dir" --json list)"
[ "$(printf '%s\n' "$out" | jq -r 'length')" = "2" ]
[ "$(printf '%s\n' "$out" | jq -r '.[] | select(.candidate=="cand-b") | .state')" = "dogfood_red" ]

echo "ok last-stack-canary-pipeline"
