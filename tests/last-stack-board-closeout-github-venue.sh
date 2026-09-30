#!/usr/bin/env bash
# Proof: board-closeout-sweep reads GitHub PRs through `gh` (PATH stub) and
# treats a retired lastgit:// CR as unreadable, not as merged or closed.
#
#   gh-merged       GitHub PR MERGED                     -> closeout runs (done)
#   gh-closed-new   PR CLOSED, another OPEN PR on the    -> stays in doing, the
#                   same head branch                        newer PR is restored
#   gh-closed       PR CLOSED, no other PR               -> todo, pr_url cleared
#   lastgit-retired lastgit://.../cr/... URL             -> stays in doing, flagged
#                                                           lastgit-retired, no lastgit call
# Both engines (node and python3).
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
card() {
  printf '{"slug":"%s","title":"t","column":"doing","position":"%s","assignee":"","tags":[],"pr_url":"%s","branch":"%s","repo":"EdgeVector/widget","updated_at":"2020-01-01T00:00:00.000Z","body":"Repo: EdgeVector/widget\\nBase: main\\nKind: pr\\n"}' "$1" "$2" "$3" "$4"
}
case "${1:-}" in
  list)
    printf '['
    card gh-merged 1 https://github.com/EdgeVector/widget/pull/10 kanban/gh-merged; printf ','
    card gh-closed-new 2 https://github.com/EdgeVector/widget/pull/20 kanban/gh-closed-new; printf ','
    card gh-closed 3 https://github.com/EdgeVector/widget/pull/30 kanban/gh-closed; printf ','
    card lastgit-retired 4 lastgit://widget/cr/cr-abc-1234 kanban/lastgit-retired
    printf ']\n'
    ;;
  show) printf '{"slug":"%s","column":"doing"}\n' "${2:-}" ;;
  add) printf '%s\n' "$*" >>"${BOARD_ADDS:?}" ;;
  move) printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}" ;;
  set|mark|tag) : ;;
  *) echo "unexpected board command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "${3:-}" in
    10) echo '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z","headRefName":"kanban/gh-merged"}' ;;
    20) echo '{"state":"CLOSED","mergedAt":null,"headRefName":"kanban/gh-closed-new"}' ;;
    30) echo '{"state":"CLOSED","mergedAt":null,"headRefName":"kanban/gh-closed"}' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  case "$*" in
    *"--head kanban/gh-closed-new"*) echo '[{"number":21,"url":"https://github.com/EdgeVector/widget/pull/21"}]' ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
exit 1
EOF
cat >"$bin/lastgit" <<'EOF'
#!/usr/bin/env bash
echo "lastgit must not be called" >>"${GH_LOG:?}"
exit 1
EOF
chmod +x "$bin/gh" "$bin/lastgit"

stack="$tmp/stack"
mkdir -p "$stack/bin" "$tmp/home"
cp "$sweep" "$stack/bin/last-stack-board-closeout-sweep"
cat >"$stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${BOARD_CLOSED:?}"
exit 0
EOF
chmod +x "$stack/bin/last-stack-board-closeout-sweep" "$stack/bin/last-stack-card-closeout"
export PATH="$bin:$PATH"

fail=0
for engine in node python3; do
  if [ "$engine" = node ] && ! command -v node >/dev/null 2>&1; then echo "skip: no node"; continue; fi
  export GH_LOG="$tmp/gh.$engine" BOARD_MOVES="$tmp/moves.$engine" BOARD_ADDS="$tmp/adds.$engine" BOARD_CLOSED="$tmp/closed.$engine"
  : >"$GH_LOG"; : >"$BOARD_MOVES"; : >"$BOARD_ADDS"; : >"$BOARD_CLOSED"
  out="$(HOME="$tmp/home" BOARD_CLOSEOUT_ENGINE="$engine" "$stack/bin/last-stack-board-closeout-sweep" \
    --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
  echo "--- $engine ---"; echo "$out"
  check() { if ! eval "$2"; then echo "FAIL[$engine]: $1" >&2; fail=1; fi; }
  check "gh-merged must reach closeout" 'grep -qx gh-merged "$BOARD_CLOSED"'
  check "gh-closed-new must stay in doing" '! grep -q "^gh-closed-new " "$BOARD_MOVES"'
  check "gh-closed-new must flag the open branch PR" 'echo "$out" | grep -q "open-branch-pr-preserved:gh-closed-new:gh#21"'
  check "gh-closed-new must restore PR 21" 'grep -q "add gh-closed-new --pr-url https://github.com/EdgeVector/widget/pull/21" "$BOARD_ADDS"'
  check "gh-closed must roll back to todo" 'grep -q "^gh-closed todo" "$BOARD_MOVES"'
  check "gh-closed must clear pr_url and branch" 'grep -qE "add gh-closed --pr-url  --branch( |$)" "$BOARD_ADDS"'
  check "lastgit-retired must stay in doing" '! grep -q "^lastgit-retired " "$BOARD_MOVES" && ! grep -qx lastgit-retired "$BOARD_CLOSED"'
  check "lastgit-retired must be flagged" 'echo "$out" | grep -q "lastgit-retired:widget/cr-abc-1234"'
  check "lastgit must never run" '! grep -q "lastgit must not be called" "$GH_LOG"'
done
[ "$fail" -eq 0 ] || exit 1
echo "ok last-stack-board-closeout-github-venue"
