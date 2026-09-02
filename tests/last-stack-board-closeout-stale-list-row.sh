#!/usr/bin/env bash
# Proof: board-closeout-sweep confirms the column against `show` (Card truth)
# before it moves a card. `kanban list --column doing` can serve a stale
# BoardCards row for a card that already moved to done; the sweep must not
# demote or roll that card. When show is unavailable the sweep fails open and
# keeps the legacy list-driven behavior.
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
    # Three deploy-parked rows the list reports in doing.
    cat <<'JSON'
[
  {
    "slug": "done-but-listed",
    "title": "done card still served in doing by list",
    "column": "doing",
    "position": "2",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "truly-doing-park",
    "title": "deploy park whose Card tip is doing",
    "column": "doing",
    "position": "3",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "show-fails-park",
    "title": "deploy park where show is unavailable",
    "column": "doing",
    "position": "4",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  }
]
JSON
    ;;
  show)
    case "${2:-}" in
      done-but-listed)
        printf '{"slug":"done-but-listed","column":"done","board":"default"}\n' ;;
      truly-doing-park)
        printf '{"slug":"truly-doing-park","column":"doing","board":"default"}\n' ;;
      *)
        echo "show unavailable" >&2
        exit 3 ;;
    esac
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

out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"

# A card whose Card tip is done must never be moved, whatever list says.
if grep -q '^done-but-listed ' "$moves" 2>/dev/null; then
  echo "FAIL: sweep moved a card whose show column is done:" >&2
  cat "$moves" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'stale-list-row:done-but-listed:done'; then
  echo "FAIL: expected stale-list-row flag for done-but-listed" >&2
  exit 1
fi

# A deploy park whose Card tip is doing is still demoted to backlog.
if ! grep -q '^truly-doing-park backlog' "$moves"; then
  echo "FAIL: expected truly-doing-park demoted to backlog:" >&2
  cat "$moves" >&2
  exit 1
fi

# Show unavailable: fail open, legacy behavior demotes to backlog.
if ! grep -q '^show-fails-park backlog' "$moves"; then
  echo "FAIL: expected show-fails-park demoted to backlog (fail open):" >&2
  cat "$moves" >&2
  exit 1
fi

echo "ok last-stack-board-closeout-stale-list-row"
