#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-no-scan-access
# Terminal tracker gate for keyed first-party LastDB access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-no-scan-access
TRACKER_SLUG=lastdb-scan-deprecation-tracker
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/no-scan-proof.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

tracker="$TMP/tracker.json"
failure=""

if [ -n "${LASTDB_NO_SCAN_TRACKER_FILE:-}" ]; then
  if [ -f "$LASTDB_NO_SCAN_TRACKER_FILE" ]; then
    cp "$LASTDB_NO_SCAN_TRACKER_FILE" "$tracker"
  else
    failure="tracker fixture is absent"
  fi
elif [ "$MODE" = live ] && command -v kanban >/dev/null 2>&1; then
  if ! kanban show "$TRACKER_SLUG" --json >"$tracker"; then
    failure="$TRACKER_SLUG is absent"
  fi
else
  failure="live keyed read or tracker fixture is required"
fi

if [ -z "$failure" ] && ! jq -e --arg slug "$TRACKER_SLUG" '
    .slug == $slug and
    .kind == "tracker" and
    .column == "done" and
    (.body | contains("## COMPLETION RULE")) and
    (.body | contains("PROOF:"))
  ' "$tracker" >/dev/null; then
  failure="tracker is not done or lacks its completion proof"
fi

if [ "$MODE" != live ]; then
  failure="offline mode cannot satisfy the live tracker contract"
fi

if [ -n "$failure" ]; then
  ns_write_report "$SLUG" FAIL \
    "- closed tracker ${TRACKER_SLUG}: FAIL — ${failure}"
  exit 1
fi

ns_write_report "$SLUG" PASS \
  "- closed tracker ${TRACKER_SLUG}: PASS

Mode: live. The harness uses one keyed tracker read. It never scans, restarts, or mutates LastDB."
