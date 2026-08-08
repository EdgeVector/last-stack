#!/usr/bin/env bash
# Proof: a deploy-gated park is a DELAY, not a permanent exemption.
#
# A card tagged awaiting-deploy with no resolvable PR used to sit in `doing`
# forever — nothing reclaimed it, so a card whose worker was paused stayed
# parked indefinitely. --max-park-hours bounds that park.
#
# Asserts, on both engines (node + python3 fallback):
#   1. parked card older than the bound  → moved to todo, flagged park-expired
#   2. parked card younger than the bound → left in doing, flagged deploy-parked
#   3. transient board failure            → NEVER park-expired (board was sick,
#                                           not the card)
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
  add|tag)
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

  # 1. Old park is bounded — reclaimed to todo.
  echo "$out" | grep -q 'park-expired:parked-old' || {
    echo "FAIL[$engine]: expected park-expired for parked-old: $out" >&2
    exit 1
  }
  grep -q '^parked-old todo$' "$moves" || {
    echo "FAIL[$engine]: expected parked-old moved to todo:" >&2
    cat "$moves" >&2
    exit 1
  }

  # 2. Fresh park still protected — the bound must not become a stampede.
  if echo "$out" | grep -q 'park-expired:parked-fresh'; then
    echo "FAIL[$engine]: fresh park was expired: $out" >&2
    exit 1
  fi
  if grep -q '^parked-fresh todo$' "$moves"; then
    echo "FAIL[$engine]: fresh park was rolled back:" >&2
    cat "$moves" >&2
    exit 1
  fi
  echo "$out" | grep -q 'deploy-parked:parked-fresh' || {
    echo "FAIL[$engine]: expected parked-fresh to stay deploy-parked: $out" >&2
    exit 1
  }

  # 3. A huge bound must disable expiry entirely (regression guard on parsing).
  : >"$moves"
  wide="$("${run_env[@]}" "$sweep" --board-cli "$board" --grace-min 1 \
    --max-park-hours 999999 --max-actions 20 2>&1 || true)"
  if echo "$wide" | grep -q 'park-expired:'; then
    echo "FAIL[$engine]: --max-park-hours 999999 still expired a park: $wide" >&2
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
  add|tag)
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
