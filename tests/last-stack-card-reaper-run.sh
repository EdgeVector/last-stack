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
    "slug": "stale-child",
    "title": "Stale child protected by capstone",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "live-capstone",
    "title": "Live capstone",
    "column": "backlog",
    "created_at": "2026-07-15T12:00:00Z",
    "deps": ["stale-child"]
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
printf '%s\n' "$out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=5 killed=<backlog=0,todo=1,doing=0> rolled_back=0 salvaged=0 exempt_needs_human=1 flagged=live-dependent-protected:stale-child,needs-human-aging:human-blocked-old,dry-run$'
! printf '%s\n' "$out" | grep -q '^would_kill stale-child:'
test ! -e "$tmp/memory.md"

transient_board="$tmp/transient-board.json"
cat >"$transient_board" <<'JSON'
[
  {
    "slug": "transient-add",
    "title": "Transient add failure",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  }
]
JSON

fake_bin="$tmp/bin"
mkdir -p "$fake_bin" "$tmp/no-last-stack"
cat >"$fake_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    cat <<'JSON'
{"slug":"transient-add","body":"## END STATE\nDone."}
JSON
    ;;
  add)
    echo "service_timeout: node did not respond within 30000ms" >&2
    exit 1
    ;;
  rm|move)
    echo "unexpected destructive mutation after add failure: $*" >&2
    exit 2
    ;;
  *)
    echo "unexpected kanban command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/kanban"

transient_out="$(PATH="$fake_bin:$PATH" LAST_STACK_ROOT="$tmp/no-last-stack" "$ROOT/bin/last-stack-card-reaper-run" \
  --skip-preflight \
  --board-json "$transient_board" \
  --memory "$tmp/transient-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$transient_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z noop live=1 killed=<backlog=0,todo=0,doing=0> rolled_back=0 salvaged=0 exempt_needs_human=0 flagged=board-add-deferred:transient-add$'
! printf '%s\n' "$transient_out" | grep -q 'exception:kanban_add_failed'
test ! -e "$tmp/transient-memory.md"

echo "ok last-stack-card-reaper-run"
