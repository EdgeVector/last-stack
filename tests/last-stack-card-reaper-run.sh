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
    "slug": "stale-doing-dep",
    "title": "Stale doing with live dependent",
    "column": "doing",
    "created_at": "2026-07-15T12:00:00Z"
  },
  {
    "slug": "stale-todo-dep",
    "title": "Stale todo with live dependent",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z"
  },
  {
    "slug": "capstone-live",
    "title": "Live capstone",
    "column": "backlog",
    "created_at": "2026-07-20T12:00:00Z",
    "deps": ["stale-doing-dep", "stale-todo-dep"]
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

printf '%s\n' "$out" | grep -q '^would_roll_back stale-doing-dep: doing dead claim with live dependents; age=121.5h dependents=capstone-live$'
printf '%s\n' "$out" | grep -q '^would_kill stale-todo: todo stale >72h with no progress; age=121.5h$'
printf '%s\n' "$out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=6 killed=<backlog=0,todo=1,doing=0> rolled_back=1 salvaged=0 exempt_needs_human=1 flagged=protected-live-dependent:stale-doing-dep,protected-live-dependent:stale-todo-dep,needs-human-aging:human-blocked-old,dry-run$'
test ! -e "$tmp/memory.md"

echo "ok last-stack-card-reaper-run"
