#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-canary-pipeline-v2
# Terminal proof for the LastDB canary pipeline v2 contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-canary-pipeline-v2
MODE="$(ns_mode)"
PIPELINE="$ROOT/bin/last-stack-canary-pipeline"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

[ -x "$PIPELINE" ] || fail "missing canary pipeline command: $PIPELINE"
grep -q '^def durable_verdict' "$PIPELINE" || fail "missing durable v2 verdict function"
grep -q 'def proof' "$PIPELINE" || fail "missing dry-run proof command"

set +e
proof_out="$("$PIPELINE" proof --dry-run 2>&1)"
proof_rc=$?
set -e

body="$(printf '%s\n\nMode: %s\nCommand: `%s proof --dry-run`\nExit status: %s\n\n```text\n%s\n```\n\n%s' \
  'LastDB canary pipeline v2 terminal proof.' "$MODE" "$PIPELINE" "$proof_rc" "$proof_out" \
  'The proof command is dry run only. It must report `no_primary_mutation=1` and `stable_mutation=false` before this harness accepts the result.')"

[ "$proof_rc" -eq 0 ] || fail "$body"
printf '%s\n' "$proof_out" | grep -q 'result=ok' || fail "$body"
printf '%s\n' "$proof_out" | grep -q 'no_primary_mutation=1' || fail "$body"
printf '%s\n' "$proof_out" | grep -q 'stable_mutation=false' || fail "$body"

if [ "$MODE" = live ]; then
  ns_write_report "$SLUG" PASS "$body"
else
  ns_write_report "$SLUG" PASS-OFFLINE "$body"
fi
