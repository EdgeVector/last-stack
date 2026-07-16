#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

json='{"app_id":"brain","cert":{"authorized_publisher":true},"schemas":[{"name":"Concept"}],"meta":null}'

got="$(printf '%s\n' "$json" | "$ROOT/bin/last-stack-json-get" .app_id)"
[ "$got" = "brain" ] || { echo "expected app_id, got: $got" >&2; exit 1; }

got="$(printf '%s\n' "$json" | "$ROOT/bin/last-stack-json-get" .cert.authorized_publisher)"
[ "$got" = "true" ] || { echo "expected boolean true, got: $got" >&2; exit 1; }

got="$(printf '%s\n' "$json" | "$ROOT/bin/last-stack-json-get" .schemas[0].name)"
[ "$got" = "Concept" ] || { echo "expected array field, got: $got" >&2; exit 1; }

got="$(printf '%s\n' "$json" | "$ROOT/bin/last-stack-json-get" .meta)"
[ "$got" = "null" ] || { echo "expected null, got: $got" >&2; exit 1; }

if printf '%s\n' "$json" | "$ROOT/bin/last-stack-json-get" .missing >/tmp/last-stack-json-get.out 2>/tmp/last-stack-json-get.err; then
  echo "expected missing field to fail" >&2
  exit 1
fi
grep -q 'field not found' /tmp/last-stack-json-get.err

echo "ok"
