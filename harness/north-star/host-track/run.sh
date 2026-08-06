#!/usr/bin/env bash
# north-star-slug: north-star-host-track
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-host-track
MODE="$(ns_mode)"
APP="${HOST_TRACK_PROOF_APP:-last-stack}"
host_track_bin="${HOST_TRACK_BIN:-$ROOT/bin/host-track}"
registry="${HOST_TRACK_REGISTRY:-$ROOT/config/host-track/apps.json}"

if [ ! -x "$host_track_bin" ]; then
  ns_write_report "$SLUG" FAIL "missing Host Track binary: $host_track_bin" || exit 1
  exit 1
fi

set +e
status_out="$(HOST_TRACK_REGISTRY="$registry" "$host_track_bin" status --json "$APP" 2>&1)"
status_rc=$?
if [ "${HOST_TRACK_PROOF_DEEP_CHECK:-0}" = "1" ]; then
  check_out="$(HOST_TRACK_REGISTRY="$registry" "$host_track_bin" check "$APP" 2>&1)"
  check_rc=$?
else
  check_out="skipped; set HOST_TRACK_PROOF_DEEP_CHECK=1 to hash-check the active artifact"
  check_rc=0
fi
set -e

body="$(cat <<EOF
Host Track install proof.

Mode: $MODE
App: $APP
Registry: $registry
Host Track: $host_track_bin

status rc=$status_rc
\`\`\`json
$status_out
\`\`\`

deep check rc=$check_rc
\`\`\`text
$check_out
\`\`\`
EOF
)"

if [ "$status_rc" -ne 0 ] || [ "$check_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$body" || exit 1
  exit 1
fi

if ! printf '%s\n' "$status_out" | jq -e --arg app "$APP" '
  (if type == "array" then .[0] else . end) as $s
  | ($s.app // $app) == $app
  | . and (($s.stale // false) == false)
' >/dev/null 2>&1; then
  ns_write_report "$SLUG" FAIL "$(printf '%s\n\nstatus output did not prove app=%s stale=false' "$body" "$APP")" || exit 1
  exit 1
fi

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$body"
