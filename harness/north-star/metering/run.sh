#!/usr/bin/env bash
# north-star-slug: north-star-storage-metering-correctness
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-storage-metering-correctness
WS="$(ns_edgevector_workspace)"
REPO="$WS/fold"
MODE="$(ns_mode)"
audit="$REPO/scripts/agent/audit-storage-metering.sh"

if [ ! -f "$audit" ]; then
  ns_write_report "$SLUG" FAIL "missing $audit" || exit 1
  exit 1
fi

notes="audit-storage-metering.sh present"
if [ "$MODE" = offline ]; then
  # Static contract: script requires API key and is off hot path
  if ! grep -q 'NOT on the sync hot path' "$audit"; then
    ns_write_report "$SLUG" FAIL "audit script missing hot-path safety comment" || exit 1
    exit 1
  fi
  if ! grep -q 'EXEMEM_API_KEY' "$audit"; then
    ns_write_report "$SLUG" FAIL "audit script missing EXEMEM_API_KEY gate" || exit 1
    exit 1
  fi
  ns_write_report "$SLUG" PASS-OFFLINE "$(printf 'Metering audit probe contract verified (off hot path, key-gated).\nLive: EXEMEM_API_KEY=… %s\n\n%s\n' "$audit" "$notes")"
  exit 0
fi

if [ -z "${EXEMEM_API_KEY:-}" ]; then
  ns_write_report "$SLUG" FAIL "live mode requires EXEMEM_API_KEY (use LastSecrets at point of use)" || exit 1
  exit 1
fi
set +e
out="$(bash "$audit" 2>&1)"
rc=$?
set -e
notes="$(printf 'audit-storage-metering rc=%s\n```\n%s\n```\n' "$rc" "$out")"
if [ "$rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$notes" || exit 1
  exit 1
fi
ns_write_report "$SLUG" PASS "$notes"
