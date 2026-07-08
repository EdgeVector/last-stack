#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

raw_json='{"state":"open","mergeable":true,"body":"line one
	line two","statuses":{"total_count":2}}'

if printf '%s' "$raw_json" | jq -r '.state' >/dev/null 2>&1; then
  echo "expected raw control-character JSON to fail with plain jq" >&2
  exit 1
fi

out="$(
  printf '%s' "$raw_json" |
    "$ROOT/bin/last-stack-forge-json-jq" -r '[.state, (.mergeable|tostring), (.statuses.total_count|tostring)] | @tsv'
)"

test "$out" = $'open\ttrue\t2'

echo "ok"
