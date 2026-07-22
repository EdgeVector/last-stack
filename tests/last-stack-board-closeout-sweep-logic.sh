#!/usr/bin/env bash
# Unit-ish proof: board-closeout-sweep heals pr_url from body, parks deploy-gated
# cards, and does not roll them back to todo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/board"
moves="$tmp/moves"
heals="$tmp/heals"
tags="$tmp/tags"
: >"$moves"
: >"$heals"
: >"$tags"

cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    # emit one deploy-gated doing card with body PR but empty structured pr_url
    cat <<'JSON'
[
  {
    "slug": "deploy-pipeline-red-schema-infra-20260722",
    "title": "P0 schema-infra deploy",
    "column": "doing",
    "position": "9999999999999",
    "assignee": "",
    "tags": ["pipeline", "p0"],
    "pr_url": "",
    "branch": "kanban/deploy-pipeline-red-schema-infra-20260722-build-once",
    "repo": "EdgeVector/schema-infra",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/schema-infra\nBase: main\nKind: pr\nBranch: kanban/deploy-pipeline-red-schema-infra-20260722-build-once\nPR: lastgit://schema-infra/cr/cr-mrw0frwz-ea84\nRequires-Deploy: deploy-pipeline\n\n## LIVE PROOF\nReturning the card — do not mark done until deploy-pipeline is terminal success.\n"
  },
  {
    "slug": "empty-zombie-old",
    "title": "empty zombie",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "nothing here"
  }
]
JSON
    ;;
  add)
    # heal path: add <slug> --pr-url <url>
    printf '%s\n' "$*" >>"${BOARD_HEALS:?}"
    ;;
  tag)
    printf '%s\n' "$*" >>"${BOARD_TAGS:?}"
    ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

# Intercept lastgit / closeout so merged classification fails open as open-or-unknown
# and we never hit real network. PATH wrapper:
binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/lastgit" <<'EOF'
#!/usr/bin/env bash
# Pretend CR is still open so we exercise heal + skip path.
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  cat <<'JSON'
{"cr":{"state":"open","id":"cr-mrw0frwz-ea84"}}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/lastgit"
# No last-stack-card-closeout in PATH → close path unused for open CR

export PATH="$binwrap:$PATH"
export BOARD_MOVES="$moves"
export BOARD_HEALS="$heals"
export BOARD_TAGS="$tags"

out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"

# Deploy-gated card must NOT move to todo
if grep -q 'deploy-pipeline-red-schema-infra-20260722 todo' "$moves" 2>/dev/null; then
  echo "FAIL: deploy-gated card was rolled back to todo:" >&2
  cat "$moves" >&2
  exit 1
fi

# pr_url heal must have been attempted for the body PR
if ! grep -q 'pr-url lastgit://schema-infra/cr/cr-mrw0frwz-ea84' "$heals"; then
  # board cli gets: add slug --pr-url url  (order may vary)
  if ! grep -q 'lastgit://schema-infra/cr/cr-mrw0frwz-ea84' "$heals"; then
    echo "FAIL: expected pr_url heal from body header:" >&2
    cat "$heals" >&2
    echo "out=$out" >&2
    exit 1
  fi
fi

# Empty zombie should roll back
if ! grep -q 'empty-zombie-old todo' "$moves"; then
  echo "FAIL: expected empty zombie rolled to todo:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi

echo "$out" | grep -q 'pr-url-healed:deploy-pipeline-red-schema-infra-20260722' || {
  echo "FAIL: expected pr-url-healed flag in heartbeat: $out" >&2
  exit 1
}

echo "ok last-stack-board-closeout-sweep-logic"
