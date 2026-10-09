#!/usr/bin/env bash
# Proof: board-closeout-sweep must not roll a card back to `todo` when the card
# branch is already merged into its base ref.
#
# A PR record can read CLOSED with no mergedAt although the work landed on the
# base ref (a manual close racing the auto-merge). The git ref outranks it, so the
# sweep used to roll shipped work back into `todo`, where pickup re-claimed it
# and burned a whole worker budget re-proving code already on main.
#
# Fixture 1 (merged):     closed PR + branch IS an ancestor of base -> done.
# Fixture 2 (not merged): closed PR + branch is NOT an ancestor     -> todo.
# Both fixtures run on both engines (node and python3).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
source "$ROOT/tests/fixtures/factory-closeout-dependencies.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- a real git repo so merge-base --is-ancestor answers for real -----------
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
echo base >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -qm base

# merged branch: created, then fast-forwarded into main
git -C "$repo" checkout -qb kanban/merged-card
echo shipped >>"$repo/f"
git -C "$repo" commit -qam shipped
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff -m "merge shipped" kanban/merged-card

# unmerged branch: diverges from main and never lands
git -C "$repo" checkout -qb kanban/unmerged-card
echo wip >>"$repo/f"
git -C "$repo" commit -qam wip
git -C "$repo" checkout -q main

# The sweep looks for a worktree named after the slug; point both slugs at the
# same repo so branch + base refs resolve without a network or a real checkout.
wtroot="$tmp/worktrees"
mkdir -p "$wtroot"
cp -R "$repo" "$wtroot/merged-card"
cp -R "$repo" "$wtroot/unmerged-card"

# --- fake board CLI ---------------------------------------------------------
board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  guarded-snapshot)
    exec "${FACTORY_CLOSEOUT_FIXTURE_NATIVE:?}" --cards-file "$0.cards.json" "$@"
    ;;
  list)
    cat <<JSON
[
  {
    "slug": "merged-card",
    "title": "closed CR whose branch already reached main",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "https://github.com/EdgeVector/last-stack/pull/9001",
    "branch": "kanban/merged-card",
    "base": "main",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n"
  },
  {
    "slug": "unmerged-card",
    "title": "genuinely closed CR, branch never landed",
    "column": "doing",
    "position": "2",
    "assignee": "",
    "tags": [],
    "pr_url": "https://github.com/EdgeVector/last-stack/pull/9002",
    "branch": "kanban/unmerged-card",
    "base": "main",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  show)
    case "${2:-}" in
      merged-card|unmerged-card)
        printf '{"slug":"%s","column":"doing"}\n' "${2:-}"
        ;;
      *)
        echo "unexpected show: $*" >&2
        exit 2
        ;;
    esac
    ;;
  add)
    printf '%s\n' "$*" >>"${BOARD_ADDS:?}"
    ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  set|mark|tag)
    : ;;
  *)
    echo "unexpected board command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

# --- stub gh: both PRs read CLOSED with no mergedAt (the closed-not-merged shape)
binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  echo '{"state":"CLOSED","mergedAt":null,"headRefName":""}'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  echo '[]'
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/gh"

# The sweep resolves closeout/reclaim helpers from lastStack/bin, not PATH.
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

fixture_closeout_native_dependencies "$fake_stack" "$board"
fixture_closeout_prepare_native_cards "$board"
export BOARD_CLOSEOUT_STATE_DIR="$tmp/closeout-state"
export PATH="$binwrap:$PATH"

run_engine() {
  # $1 = node|python3
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

# The sweep discovers worktrees under $HOME/.fkanban/worktrees.
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
  echo "--- engine=$engine ---"
  echo "$out"

  # Fixture 1: merged branch closes to done and never rolls back.
  if ! grep -q '^merged-card done' "$moves"; then
    echo "FAIL[$engine]: merged-card did not close to done" >&2
    cat "$moves" >&2
    fail=1
  fi
  if grep -q '^merged-card todo' "$moves"; then
    echo "FAIL[$engine]: merged-card was rolled back to todo" >&2
    cat "$moves" >&2
    fail=1
  fi
  if ! echo "$out" | grep -q 'merge-proof-close:merged-card'; then
    echo "FAIL[$engine]: expected merge-proof-close flag for merged-card" >&2
    fail=1
  fi

  # Fixture 2: a genuinely closed CR still rolls back to todo.
  if ! grep -q '^unmerged-card todo' "$moves"; then
    echo "FAIL[$engine]: unmerged-card should still roll back to todo" >&2
    cat "$moves" >&2
    fail=1
  fi
  if grep -q '^unmerged-card done' "$moves"; then
    echo "FAIL[$engine]: unmerged-card must not be closed" >&2
    fail=1
  fi

  # The closed PR URL must not be restamped on a merge-proof close.
  if grep -E '^add merged-card --pr-url https://github.com' "$tmp/adds.$engine" >/dev/null 2>&1; then
    echo "FAIL[$engine]: corrupt pr_url was restamped on merge-proof close" >&2
    cat "$tmp/adds.$engine" >&2
    fail=1
  fi
done

# Dry-run must report the merged card as closed, not rolled back.
dry="$(env HOME="$tmp/home" BOARD_MOVES="$tmp/moves.dry" BOARD_ADDS="$tmp/adds.dry" \
  "$fake_stack/bin/last-stack-board-closeout-sweep" --dry-run \
    --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "--- dry-run ---"
echo "$dry"
echo "$dry" | grep -q 'closed_slugs=merged-card' || {
  echo "FAIL: dry-run did not report merged-card as closed" >&2
  fail=1
}

# An invalid engine name must fail loudly rather than silently pick one.
if env HOME="$tmp/home" BOARD_CLOSEOUT_ENGINE=bogus \
  "$fake_stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" >/dev/null 2>&1; then
  echo "FAIL: BOARD_CLOSEOUT_ENGINE=bogus was accepted" >&2
  fail=1
fi

# A usage error must precede the independent factory contract preflight.
# A valid contract above alone cannot expose this order regression.
mv "$fake_stack/bin/last-stack-factory-repair-contract" "$fake_stack/bin/factory-contract-held"
if env HOME="$tmp/home" BOARD_CLOSEOUT_ENGINE=bogus \
  "$fake_stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" \
  >"$tmp/bogus-no-contract.out" 2>"$tmp/bogus-no-contract.err"; then
  bogus_rc=0
else
  bogus_rc=$?
fi
if [ "$bogus_rc" != 2 ] || ! grep -q 'BOARD_CLOSEOUT_ENGINE must be node|python3|auto' "$tmp/bogus-no-contract.err"; then
  echo "FAIL: invalid engine with absent factory contract must exit 2" >&2
  cat "$tmp/bogus-no-contract.out" "$tmp/bogus-no-contract.err" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "ok last-stack-board-closeout-merge-proof-guard"
