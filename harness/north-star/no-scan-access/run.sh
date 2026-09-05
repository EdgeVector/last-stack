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

seed_tracker() {
  # Idempotent keyed seed so a board wipe cannot silently drop this slug
  # again (it happened once, 2026-09-01 -> discovered 2026-09-04). Never
  # marks the card done — the fail-closed gate below still requires a real
  # COMPLETION RULE + PROOF before this tracker can pass.
  kanban add "$TRACKER_SLUG" \
    --title "Track the original LastDB scan-deprecation fan-out" \
    --column backlog \
    --kind tracker \
    --north-star north-star-lastdb-no-scan-access \
    --tags no-scan,tracker \
    --body "$(cat <<'SEED'
Kind: tracker
Repo: EdgeVector/last-stack
Base: main

Track the original LastDB scan-deprecation fan-out for
north-star-lastdb-no-scan-access.

## COMPLETION RULE

This tracker moves to done only when BOTH are true and this body carries a
PROOF: line naming the live evidence for each:

1. Grep gate - every first-party app has zero unfiltered queryAll /
   listRecords / listCards full-schema drains on default CLI/MCP/daemon
   paths.
2. Live ops proof - a lastdb ops sample taken during normal dogfood shows
   no multi-hundred-row unfiltered query as the top total_ms consumer for
   kanban or lastgit.

Re-seeded by harness/north-star/no-scan-access/run.sh because the card was
absent on a live proof run. See north-star-lastdb-no-scan-access for the
per-app fan-out completion history.
SEED
)" \
    >/dev/null 2>&1
}

if [ -n "${LASTDB_NO_SCAN_TRACKER_FILE:-}" ]; then
  if [ -f "$LASTDB_NO_SCAN_TRACKER_FILE" ]; then
    cp "$LASTDB_NO_SCAN_TRACKER_FILE" "$tracker"
  else
    failure="tracker fixture is absent"
  fi
elif [ "$MODE" = live ] && command -v kanban >/dev/null 2>&1; then
  if ! kanban show "$TRACKER_SLUG" --json >"$tracker" 2>/dev/null; then
    seed_tracker
    if ! kanban show "$TRACKER_SLUG" --json >"$tracker" 2>/dev/null; then
      failure="$TRACKER_SLUG is absent"
    fi
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
