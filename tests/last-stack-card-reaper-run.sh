#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

board="$tmp/board.json"
cat >"$board" <<'JSON'
[
  {
    "slug": "fresh-todo",
    "title": "Fresh todo",
    "column": "todo",
    "created_at": "2026-07-20T12:00:00Z"
  },
  {
    "slug": "stale-todo",
    "title": "Stale todo",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "human-blocked-old",
    "title": "Human blocked old",
    "column": "backlog",
    "created_at": "2026-07-01T12:00:00Z",
    "block_status": "needs_human"
  },
  {
    "slug": "done-card",
    "title": "Done",
    "column": "done",
    "created_at": "2026-07-01T12:00:00Z"
  }
]
JSON

out="$("$ROOT/bin/last-stack-card-reaper-run" \
  --dry-run \
  --skip-preflight \
  --board-json "$board" \
  --memory "$tmp/memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$out" | grep -q '^would_kill stale-todo: todo stale >72h with no progress; age=121.5h$'
printf '%s\n' "$out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=3 killed=<backlog=0,todo=1,doing=0> rolled_back=0 salvaged=0 exempt_needs_human=1 flagged=needs-human-aging:human-blocked-old,dry-run$'
test ! -e "$tmp/memory.md"

echo "ok last-stack-card-reaper-run"
