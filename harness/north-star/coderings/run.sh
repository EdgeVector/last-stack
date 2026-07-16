#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-coderings
WS="$(ns_edgevector_workspace)"
REPO="$WS/coderings"
MODE="$(ns_mode)"

if [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/package.json" ]; then
  ns_write_report "$SLUG" FAIL "coderings checkout missing at $REPO" || exit 1
  exit 1
fi
ns_require_cmd bun

cd "$REPO"
# Default exerciser uses in-process memory store — never primary brain.
set +e
out="$(bun src/cli.ts capstone exercise 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qiE 'GREEN|ok'; then
  ns_write_report "$SLUG" FAIL "$(printf 'capstone exercise failed (rc=%s)\n\n```\n%s\n```\n' "$rc" "$out")" || exit 1
  exit 1
fi

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$(printf 'CodeRings fixture/capstone exerciser green.\n\n```\n%s\n```\n\nCheckout: %s\nMode: %s\n' "$out" "$REPO" "$MODE")"
