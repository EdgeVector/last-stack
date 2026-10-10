#!/usr/bin/env bash
# north-star-slug: north-star-last-stack-north-star
# Terminal proof for the Last Stack launchd and routine-registry contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=last-stack-north-star
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-north-star-proof.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

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

for command_name in bash plutil jq; do
  if ! ns_require_cmd "$command_name"; then
    finish FAIL "The proof needs the missing command: $command_name."
  fi
done

if [ ! -x /usr/libexec/PlistBuddy ]; then
  finish FAIL "The proof needs /usr/libexec/PlistBuddy."
fi

agent_source="$ROOT/lib/last-stack-launchd-agent.sh"
registry_source="$ROOT/bin/last-stack-routines-registry-env"
for required_file in "$agent_source" "$registry_source"; do
  if [ ! -f "$required_file" ]; then
    finish FAIL "The source input is absent: $required_file."
  fi
done

body="Last Stack source files are present.

- launchd helper: $agent_source
- routine registry helper: $registry_source

Situation no-tests-all-repos-20261009 removes the old test suite proof.
This source check does not prove live launchd or registry behavior."
finish PASS-OFFLINE "$body"
