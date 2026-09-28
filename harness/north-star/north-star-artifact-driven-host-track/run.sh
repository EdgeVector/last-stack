#!/usr/bin/env bash
# north-star-slug: north-star-artifact-driven-host-track
# Terminal proof for artifact-driven Host Track upgrades.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-artifact-driven-host-track
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/artifact-host-track-proof.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP"
}
trap cleanup EXIT

finish() {
  local verdict="$1" body="$2"
  if ns_write_report "$SLUG" "$verdict" "$body"; then
    exit 0
  fi
  exit 1
}

case "$MODE" in
  offline|live) ;;
  *) finish FAIL "The proof mode is invalid: $MODE." ;;
esac

for command_name in jq shasum; do
  if ! ns_require_cmd "$command_name"; then
    finish FAIL "The proof needs the missing command: $command_name."
  fi
done

fixture_test="$ROOT/tests/last-stack-artifact-host-track-proof.sh"
fleet_gate="$ROOT/bin/last-stack-fleet-channel-freshness-gate"
live_proof="$ROOT/bin/last-stack-artifact-host-track-proof"

for required_file in "$fixture_test" "$fleet_gate" "$live_proof"; do
  if [ ! -f "$required_file" ]; then
    finish FAIL "The proof input is absent: $required_file."
  fi
done

if [ "$MODE" = offline ]; then
  set +e
  fixture_output="$(HOME="$TMP/home" bash "$fixture_test" 2>&1)"
  fixture_rc=$?
  fleet_output="$(HOME="$TMP/home" "$fleet_gate" \
    --registry "$ROOT/config/host-track/apps.json" \
    --registry-only --proof "$TMP/fleet-proof.md" 2>&1)"
  fleet_rc=$?
  set -e

  body="$(cat <<EOF
Artifact-driven Host Track terminal proof.

Mode: offline.
The fixture test creates its own throwaway HOME and artifact store.
The fleet gate checks registry policy only.
Neither command opens a LastDB home or changes shared infrastructure.

Fixture proof rc=$fixture_rc
\`\`\`text
$fixture_output
\`\`\`

Fleet registry gate rc=$fleet_rc
\`\`\`text
$fleet_output
\`\`\`
EOF
  )"

  if [ "$fixture_rc" -ne 0 ] || [ "$fleet_rc" -ne 0 ]; then
    finish FAIL "$body"
  fi
  finish PASS-OFFLINE "$body"
fi

set +e
live_output="$("$live_proof" --proof "$TMP/live-proof.md" --json 2>&1)"
live_rc=$?
set -e

body="$(cat <<EOF
Artifact-driven Host Track terminal proof.

Mode: live.
The product proof reads the configured Host Track fleet and does not perform an upgrade.

Host Track proof rc=$live_rc
\`\`\`json
$live_output
\`\`\`
EOF
)"

if [ "$live_rc" -ne 0 ]; then
  finish FAIL "$body"
fi
finish PASS "$body"
