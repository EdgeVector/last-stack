#!/usr/bin/env bash
# Proof: board-closeout refuses to mutate a card when `kanban show` fails,
# instead of falling back to a stale ownership preview that could demote or
# clear a live claim. A failed Card point-read blocks all mutation on that card.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export BOARD_CLOSEOUT_STATE_DIR="$tmp/state"

board="$tmp/board"
moves="$tmp/moves"
: >"$moves"

cat >"$board" <<'BOARD'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    cat <<'JSON'
[
  {
    "slug": "read-fails-merged-pr",
    "title": "merged PR but card show fails",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "https://forge.local/EdgeVector/fold/pulls/123",
    "branch": "kanban/read-fails-merged-pr",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\n"
  },
  {
    "slug": "read-fails-deploy-parked",
    "title": "deploy-parked card where card show fails",
    "column": "doing",
    "position": "2",
    "assignee": "user-1",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: pipeline\n"
  },
  {
    "slug": "read-fails-no-pr",
    "title": "no PR card where card show fails",
    "column": "doing",
    "position": "3",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "kanban/read-fails-no-pr",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  show)
    # All show calls fail to simulate read failure
    echo "card show is unavailable" >&2
    exit 3
    ;;
  add|tag|set|mark)
    : ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
BOARD
chmod +x "$board"

export BOARD_MOVES="$moves"

out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 50 --json 2>&1 || true)"
echo "$out"

# Verify that NO cards were moved despite stale preview data
if [ -s "$moves" ]; then
  echo "FAIL: sweep moved cards despite read failures:" >&2
  cat "$moves" >&2
  exit 1
fi

# Verify that all three cards got the card-read-failed flag
for slug in read-fails-merged-pr read-fails-deploy-parked read-fails-no-pr; do
  if ! printf '%s\n' "$out" | grep -q "card-read-failed:$slug"; then
    echo "FAIL: expected card-read-failed flag for $slug" >&2
    exit 1
  fi
done

echo "ok last-stack-board-closeout-failed-card-read"
