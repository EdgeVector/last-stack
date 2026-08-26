#!/usr/bin/env bash
# Proof: board-closeout-sweep must resolve the freshest evidence before it
# rolls a card back to todo or restamps a healed closed CR.
#
# Fixture 1 (open-newer-PR): structured PR is closed, but the latest HANDOFF
# names a newer OPEN PR → keep doing and restore the newer PR/branch.
# Fixture 2 (committed-checkpoint-no-PR): no pr_url, structured branch +
# HANDOFF-verified commit → keep doing (not wip-no-pr).
# Fixture 3 (malformed-URL-heal-still-claimable): closed LastGit CR with a
# trailing-backtick pr_url → clear pr_url AND branch in one write; do not
# restamp the sanitized closed URL.
# Control: WIP commits + structured branch but no HANDOFF still rolls back
# as wip-no-pr (the illegal no-PR handoff case).
#
# Both engines (node and python3). Sibling of
# tests/last-stack-board-closeout-merge-proof-guard.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
echo base >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -qm base

git -C "$repo" checkout -qb kanban/checkpoint-card
echo checkpoint >>"$repo/f"
git -C "$repo" commit -qam checkpoint
checkpoint_sha="$(git -C "$repo" rev-parse --short HEAD)"
git -C "$repo" checkout -q main

git -C "$repo" checkout -qb kanban/wip-no-handoff
echo wip >>"$repo/f"
git -C "$repo" commit -qam wip
git -C "$repo" checkout -q main

wtroot="$tmp/worktrees"
mkdir -p "$wtroot"
git -C "$repo" clone -q --local "$repo" "$wtroot/checkpoint-card"
git -C "$wtroot/checkpoint-card" checkout -q kanban/checkpoint-card
git -C "$repo" clone -q --local "$repo" "$wtroot/wip-no-handoff"
git -C "$wtroot/wip-no-handoff" checkout -q kanban/wip-no-handoff

board="$tmp/board"
cat >"$board" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    cat <<JSON
[
  {
    "slug": "stale-pr-card",
    "title": "closed structured PR, newer open HANDOFF",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/1675",
    "branch": "kanban/stale-pr-card",
    "base": "main",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\\nBase: main\\nKind: pr\\nHANDOFF: worktree=/tmp/stale branch=kanban/stale-pr-card pr=http://localhost:3300/EdgeVector/fold/pulls/1676 commit=43812dc93\\n"
  },
  {
    "slug": "checkpoint-card",
    "title": "committed HANDOFF, no PR",
    "column": "doing",
    "position": "2",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "kanban/checkpoint-card",
    "base": "main",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\\nBase: main\\nKind: pr\\nHANDOFF: worktree=/tmp/checkpoint-card branch=kanban/checkpoint-card commit=${checkpoint_sha}\\n"
  },
  {
    "slug": "healed-closed-cr",
    "title": "malformed closed LastGit CR URL",
    "column": "doing",
    "position": "3",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://code-atlas/cr/cr-mt3dnama-15b1).",
    "branch": "kanban/healed-closed-cr",
    "base": "main",
    "repo": "EdgeVector/code-atlas",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/code-atlas\\nBase: main\\nKind: pr\\nPR: lastgit://code-atlas/cr/cr-mt3dnama-15b1).\\n"
  },
  {
    "slug": "wip-no-handoff",
    "title": "WIP commits, no HANDOFF checkpoint",
    "column": "doing",
    "position": "4",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "kanban/wip-no-handoff",
    "base": "main",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\\nBase: main\\nKind: pr\\n"
  }
]
JSON
    ;;
  add)
    printf '%s\n' "\$*" >>"\${BOARD_ADDS:?}"
    ;;
  move)
    printf '%s %s %s\n' "\${2:-}" "\${3:-}" "\${4:-}" >>"\${BOARD_MOVES:?}"
    ;;
  set|mark|tag)
    : ;;
  *)
    echo "unexpected board command: \$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  cat <<'JSON'
{"cr":{"state":"closed","id":"cr-mt3dnama-15b1","merge_oid":""}}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/lastgit"

fake_stack="$tmp/fake-stack"
mkdir -p "$fake_stack/bin"
cp "$sweep" "$fake_stack/bin/last-stack-board-closeout-sweep"
chmod +x "$fake_stack/bin/last-stack-board-closeout-sweep"
cat >"$fake_stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
printf '%s done %s\n' "${1:-}" "closeout" >>"${BOARD_MOVES:?}"
exit 0
EOF
chmod +x "$fake_stack/bin/last-stack-card-closeout"

cat >"$fake_stack/bin/last-stack-forge-api" <<'EOF'
#!/usr/bin/env bash
# Sweep calls: last-stack-forge-api repos/Owner/Repo/pulls/N
path=""
for a in "$@"; do
  case "$a" in
    repos/*) path="$a" ;;
  esac
done
num="${path##*/}"
if [ "$num" = "1676" ]; then
  printf '%s\n' '{"state":"open","merged":false,"mergeable":true}'
  exit 0
fi
if [ "$num" = "1675" ]; then
  printf '%s\n' '{"state":"closed","merged":false}'
  exit 0
fi
printf '%s\n' '{"state":"closed","merged":false}'
exit 0
EOF
chmod +x "$fake_stack/bin/last-stack-forge-api"

export PATH="$binwrap:$PATH"

run_engine() {
  local engine="$1"
  : >"$tmp/moves.$engine"
  : >"$tmp/adds.$engine"
  BOARD_MOVES="$tmp/moves.$engine" \
  BOARD_ADDS="$tmp/adds.$engine" \
  BOARD_CLOSEOUT_ENGINE="$engine" \
  HOME="$tmp/home" \
    env HOME="$tmp/home" \
      BOARD_MOVES="$tmp/moves.$engine" \
      BOARD_ADDS="$tmp/adds.$engine" \
      BOARD_CLOSEOUT_ENGINE="$engine" \
      "$fake_stack/bin/last-stack-board-closeout-sweep" \
        --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true
}

mkdir -p "$tmp/home/.fkanban"
ln -s "$wtroot" "$tmp/home/.fkanban/worktrees"

fail=0
for engine in node python3; do
  if [ "$engine" = "node" ] && ! command -v node >/dev/null 2>&1; then
    echo "skip: node not installed"
    continue
  fi
  out="$(run_engine "$engine")"
  moves="$tmp/moves.$engine"
  adds="$tmp/adds.$engine"
  echo "--- engine=$engine ---"
  echo "$out"
  echo "moves:"
  cat "$moves" || true
  echo "adds:"
  cat "$adds" || true

  # Fixture 1: newer open HANDOFF beats closed structured PR.
  if grep -q '^stale-pr-card todo' "$moves"; then
    echo "FAIL[$engine]: stale-pr-card was rolled back to todo" >&2
    fail=1
  fi
  if grep -q '^stale-pr-card done' "$moves"; then
    echo "FAIL[$engine]: stale-pr-card must stay in doing (not close)" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'open-handoff-preserved:stale-pr-card'; then
    echo "FAIL[$engine]: expected open-handoff-preserved flag for stale-pr-card" >&2
    fail=1
  fi
  if ! grep -q 'pulls/1676' "$adds"; then
    echo "FAIL[$engine]: expected restore of newer open PR #1676" >&2
    cat "$adds" >&2
    fail=1
  fi

  # Fixture 2: checkpointed HANDOFF without a PR stays in doing.
  if grep -q '^checkpoint-card todo' "$moves"; then
    echo "FAIL[$engine]: checkpoint-card was rolled back to todo" >&2
    fail=1
  fi
  if echo "$out" | grep -q 'wip-no-pr:checkpoint-card'; then
    echo "FAIL[$engine]: checkpoint-card was flagged wip-no-pr" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'checkpoint-handoff:checkpoint-card'; then
    echo "FAIL[$engine]: expected checkpoint-handoff flag for checkpoint-card" >&2
    fail=1
  fi

  # Fixture 3: healed closed CR must not restamp the sanitized URL.
  if ! grep -q '^healed-closed-cr todo' "$moves"; then
    echo "FAIL[$engine]: healed-closed-cr should still roll back to todo" >&2
    cat "$moves" >&2
    fail=1
  fi
  if grep -E 'healed-closed-cr --pr-url lastgit://code-atlas/cr/cr-mt3dnama-15b1( |$)' "$adds" >/dev/null 2>&1; then
    echo "FAIL[$engine]: sanitized closed CR URL was restamped" >&2
    cat "$adds" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'closed-cr-cleared:healed-closed-cr'; then
    echo "FAIL[$engine]: expected closed-cr-cleared flag" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'pr-url-healed:healed-closed-cr'; then
    echo "FAIL[$engine]: expected pr-url-healed flag for dirty closed CR" >&2
    fail=1
  fi
  if ! grep -E 'add healed-closed-cr --pr-url  --branch( |$)' "$adds" >/dev/null 2>&1; then
    echo "FAIL[$engine]: expected one write clearing pr_url and branch" >&2
    cat "$adds" >&2
    fail=1
  fi

  # Control: WIP without HANDOFF still rolls back.
  if ! grep -q '^wip-no-handoff todo' "$moves"; then
    echo "FAIL[$engine]: wip-no-handoff should still roll back to todo" >&2
    cat "$moves" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'wip-no-pr:wip-no-handoff'; then
    echo "FAIL[$engine]: expected wip-no-pr flag for wip-no-handoff" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "ok last-stack-board-closeout-evidence-freshness"
