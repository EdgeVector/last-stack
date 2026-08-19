#!/usr/bin/env bash
# Proof: deploy-parked doing cards leave WIP immediately (backlog + deferred).
#
# A card tagged awaiting-deploy with no resolvable PR used to sit in `doing`
# and inflate factory-health doing_stuck_hard. Closeout now demotes those
# cards to backlog. --max-park-hours still bounds NON-deploy close-failed
# parks; deploy parks are not sent to todo (pickup thrash).
#
# Asserts, on both engines (node + python3 fallback):
#   1. parked card (old or fresh) → moved to backlog, flagged deploy-parked-demoted
#   2. parked card is NOT rolled back to todo
#   3. transient board failure    → NEVER demoted/expired (board was sick,
#                                   not the card)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    # Two deploy-parked cards, no resolvable PR. `old` predates any sane bound;
    # `fresh` is stamped by the harness to "now".
    cat <<JSON
[
  {
    "slug": "parked-old",
    "title": "awaiting deploy since forever",
    "column": "doing",
    "position": "2",
    "assignee": "last-stack-kanban-pickup-w4",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "parked-fresh",
    "title": "awaiting deploy, just parked",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "${PARK_FRESH_TS:?}",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  }
]
JSON
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${BOARD_MOVES:?}"
    ;;
  add|tag|set|mark)
    : ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

PARK_FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
export PARK_FRESH_TS

# Engine matrix: default PATH picks node; a node-free PATH exercises python3.
node_free_path="$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin"

for engine in node python3; do
  moves="$tmp/moves.$engine"
  : >"$moves"
  export BOARD_MOVES="$moves"

  if [ "$engine" = python3 ]; then
    if ! env PATH="$node_free_path" sh -c 'command -v python3 >/dev/null'; then
      echo "skip: no python3 on the node-free PATH" >&2
      continue
    fi
    if env PATH="$node_free_path" sh -c 'command -v node >/dev/null'; then
      echo "skip: could not build a node-free PATH for the fallback engine" >&2
      continue
    fi
    run_env=(env PATH="$node_free_path")
  else
    command -v node >/dev/null || { echo "skip: no node" >&2; continue; }
    run_env=(env)
  fi

  out="$("${run_env[@]}" "$sweep" --board-cli "$board" --grace-min 1 \
    --max-park-hours 24 --max-actions 20 2>&1 || true)"
  echo "[$engine] $out"

  # 1. Old park leaves doing via backlog, not todo.
  echo "$out" | grep -q 'deploy-parked-demoted:parked-old' || {
    echo "FAIL[$engine]: expected deploy-parked-demoted for parked-old: $out" >&2
    exit 1
  }
  grep -q '^parked-old backlog$' "$moves" || {
    echo "FAIL[$engine]: expected parked-old moved to backlog:" >&2
    cat "$moves" >&2
    exit 1
  }
  if grep -q '^parked-old todo$' "$moves"; then
    echo "FAIL[$engine]: parked-old was rolled back to todo:" >&2
    cat "$moves" >&2
    exit 1
  fi

  # 2. Fresh park is demoted immediately — it must not sit in doing.
  if echo "$out" | grep -q 'park-expired:parked-fresh'; then
    echo "FAIL[$engine]: fresh park was expired: $out" >&2
    exit 1
  fi
  if grep -q '^parked-fresh todo$' "$moves"; then
    echo "FAIL[$engine]: fresh park was rolled back:" >&2
    cat "$moves" >&2
    exit 1
  fi
  grep -q '^parked-fresh backlog$' "$moves" || {
    echo "FAIL[$engine]: expected parked-fresh moved to backlog:" >&2
    cat "$moves" >&2
    exit 1
  }
  echo "$out" | grep -q 'deploy-parked-demoted:parked-fresh' || {
    echo "FAIL[$engine]: expected parked-fresh to be demoted: $out" >&2
    exit 1
  }

  # 3. Deploy parks must not be expired to todo even with a tiny bound.
  : >"$moves"
  wide="$("${run_env[@]}" "$sweep" --board-cli "$board" --grace-min 1 \
    --max-park-hours 1 --max-actions 20 2>&1 || true)"
  if echo "$wide" | grep -q 'park-expired:'; then
    echo "FAIL[$engine]: deploy-parked card was park-expired to todo: $wide" >&2
    exit 1
  fi
  if grep -q ' todo$' "$moves"; then
    echo "FAIL[$engine]: deploy-parked card moved to todo:" >&2
    cat "$moves" >&2
    exit 1
  fi
done

# 4. Transient board failure must never be read as a stuck card.
transient_stack="$tmp/transient-stack"
mkdir -p "$transient_stack/bin"
cp "$sweep" "$transient_stack/bin/last-stack-board-closeout-sweep"
chmod +x "$transient_stack/bin/last-stack-board-closeout-sweep"
cat >"$transient_stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "service_timeout: board point read failed" >&2
exit 1
EOF
chmod +x "$transient_stack/bin/last-stack-card-closeout"

transient_board="$tmp/transient-board"
cat >"$transient_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "merged-but-board-sick",
    "title": "merged CR, board timing out",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://brain/cr/cr-ms8mz1xt-981a",
    "branch": "kanban/merged-but-board-sick",
    "repo": "EdgeVector/brain",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/brain\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${BOARD_MOVES:?}"
    ;;
  add|tag|set|mark)
    : ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$transient_board"

binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  cat <<'JSON'
{"cr":{"state":"merged","id":"cr-ms8mz1xt-981a","merge_oid":"abc123"}}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/lastgit"

moves="$tmp/moves.transient"
: >"$moves"
transient_out="$(env PATH="$binwrap:$PATH" BOARD_MOVES="$moves" \
  "$transient_stack/bin/last-stack-board-closeout-sweep" \
  --board-cli "$transient_board" --grace-min 1 --max-park-hours 24 \
  --max-actions 20 2>&1 || true)"
echo "[transient] $transient_out"

echo "$transient_out" | grep -q 'closeout-deferred:merged-but-board-sick' || {
  echo "FAIL: expected transient closeout deferral: $transient_out" >&2
  exit 1
}
if echo "$transient_out" | grep -q 'park-expired:'; then
  echo "FAIL: transient board failure was misread as an expired park: $transient_out" >&2
  exit 1
fi
if grep -q 'todo' "$moves" 2>/dev/null; then
  echo "FAIL: transient board failure reclaimed a card:" >&2
  cat "$moves" >&2
  exit 1
fi

echo "ok last-stack-board-closeout-park-bound"
