#!/usr/bin/env bash
# Proof: board-closeout-sweep reports WHY, keeps live PRs, and always ends
# with a terminal line.
#
# Fixture A (close-failed reason): a merged PR whose closeout refuses →
#   flag close-failed:<slug>:<reason-token> and JSON close_failed[{slug,reason}]
#   (papercut-merge-babysit-board-closeout-legacy-tip-reaper-20260922,
#    papercut-merge-babysit-board-closeout-decision-check-20260923).
# Fixture B (superseded PR on the same branch): structured PR 132 is closed,
#   merged:false, and PR 137 is open on the same head branch → keep doing,
#   restore PR 137, flag open-branch-pr-preserved
#   (papercut-pipeline-board-closeout-closed-pr-proof-unknown).
# Fixture C (definitive closed-not-merged): closed + merged:false, no open PR
#   on the branch, no checkout → roll back WITHOUT merge-proof-unknown.
# Fixture D (timeout): a board CLI that hangs → the helper still prints the
#   JSON + heartbeat pair with flagged=engine-timeout-<n>s
#   (papercut-kanban-watch-closeout-helper-no-shell-continuation-20260922).
#
# Both engines (node and python3).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {"slug":"card-a","column":"doing","position":"1","assignee":"","tags":[],
   "pr_url":"http://localhost:3300/EdgeVector/last-stack/pulls/10",
   "branch":"kanban/card-a","base":"main","repo":"EdgeVector/last-stack",
   "updated_at":"2020-01-01T00:00:00.000Z",
   "body":"Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n"},
  {"slug":"card-b","column":"doing","position":"2","assignee":"","tags":[],
   "pr_url":"http://localhost:3300/EdgeVector/last-stack/pulls/132",
   "branch":"kanban/card-b","base":"main","repo":"EdgeVector/last-stack",
   "updated_at":"2020-01-01T00:00:00.000Z",
   "body":"Repo: EdgeVector/last-stack\nBase: main\nKind: pr\nPROGRESS: PR 137 open\n"},
  {"slug":"card-c","column":"doing","position":"3","assignee":"","tags":[],
   "pr_url":"http://localhost:3300/EdgeVector/last-stack/pulls/200",
   "branch":"kanban/card-c","base":"main","repo":"EdgeVector/last-stack",
   "updated_at":"2020-01-01T00:00:00.000Z",
   "body":"Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n"}
]
JSON
    ;;
  show)
    printf '{"slug":"%s","column":"doing"}\n' "${2:-}"
    ;;
  add) printf '%s\n' "$*" >>"${BOARD_ADDS:?}" ;;
  move) printf '%s %s\n' "${2:-}" "${3:-}" >>"${BOARD_MOVES:?}" ;;
  set|mark|tag) : ;;
  *) echo "unexpected board command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

# The hung board sleeps hang_s; the watchdog fires after timeout_s. A run that
# ends before hang_s proves the watchdog, not the child, ended it.
hang_s=60
timeout_s=2
hang_board="$tmp/hang-board"
cat >"$hang_board" <<EOF
#!/usr/bin/env bash
exec sleep $hang_s
EOF
chmod +x "$hang_board"

fake_stack="$tmp/fake-stack"
mkdir -p "$fake_stack/bin"
cp "$sweep" "$fake_stack/bin/last-stack-board-closeout-sweep"
chmod +x "$fake_stack/bin/last-stack-board-closeout-sweep"
cat >"$fake_stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "card-closeout: refusing ${1:-}" >&2
echo "Add a new positive PROOF line or link a new merged review before closeout." >&2
exit 1
EOF
chmod +x "$fake_stack/bin/last-stack-card-closeout"
cat >"$fake_stack/bin/last-stack-forge-api" <<'EOF'
#!/usr/bin/env bash
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "$path" in
  */pulls\?state=open*)
    printf '%s\n' '[{"number":137,"state":"open","head":{"ref":"kanban/card-b"},"html_url":"http://localhost:3300/EdgeVector/last-stack/pulls/137"},{"number":150,"state":"open","head":{"ref":"kanban/other"}}]'
    ;;
  */pulls/10) printf '%s\n' '{"number":10,"state":"closed","merged":true,"head":{"ref":"kanban/card-a"}}' ;;
  */pulls/132) printf '%s\n' '{"number":132,"state":"closed","merged":false,"head":{"ref":"kanban/card-b"}}' ;;
  */pulls/200) printf '%s\n' '{"number":200,"state":"closed","merged":false,"head":{"ref":"kanban/card-c"}}' ;;
  *) echo "unexpected forge path: $path" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake_stack/bin/last-stack-forge-api"

mkdir -p "$tmp/home"
fail=0
for engine in node python3; do
  if [ "$engine" = "node" ] && ! command -v node >/dev/null 2>&1; then
    echo "skip: node not installed"
    continue
  fi
  : >"$tmp/moves.$engine"
  : >"$tmp/adds.$engine"
  out="$(env HOME="$tmp/home" BOARD_MOVES="$tmp/moves.$engine" \
    BOARD_ADDS="$tmp/adds.$engine" BOARD_CLOSEOUT_ENGINE="$engine" \
    "$fake_stack/bin/last-stack-board-closeout-sweep" \
      --board-cli "$board" --grace-min 1 --max-actions 20 2>/dev/null || true)"
  moves="$tmp/moves.$engine"
  adds="$tmp/adds.$engine"

  # A: the flag names the slug AND the reason; the JSON keeps the full text.
  if ! printf '%s\n' "$out" | grep -q 'close-failed:card-a:Add-a-new-positive-PROOF-line'; then
    echo "FAIL[$engine]: close-failed flag lacks the reason: $out" >&2
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -q '"close_failed":\[{"slug":"card-a","reason":"Add a new positive PROOF line'; then
    echo "FAIL[$engine]: JSON close_failed lacks slug+reason: $out" >&2
    fail=1
  fi

  # B: an open PR on the same branch keeps the card in doing.
  if grep -q '^card-b todo' "$moves"; then
    echo "FAIL[$engine]: card-b rolled back although PR 137 is open on its branch" >&2
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -q 'open-branch-pr-preserved:card-b:forge#137'; then
    echo "FAIL[$engine]: expected open-branch-pr-preserved for card-b: $out" >&2
    fail=1
  fi
  if ! grep -q 'card-b --pr-url http://localhost:3300/EdgeVector/last-stack/pulls/137' "$adds"; then
    echo "FAIL[$engine]: expected restore of PR 137 on card-b" >&2
    cat "$adds" >&2
    fail=1
  fi

  # C: closed + merged:false is definitive, not unknown.
  if ! grep -q '^card-c todo' "$moves"; then
    echo "FAIL[$engine]: card-c should roll back to todo" >&2
    fail=1
  fi
  if printf '%s\n' "$out" | grep -q 'merge-proof-unknown:card-c'; then
    echo "FAIL[$engine]: definitive closed-not-merged flagged merge-proof-unknown" >&2
    fail=1
  fi

  # D: a hung engine still ends with a terminal line.
  start=$(date +%s)
  hout="$(env HOME="$tmp/home" BOARD_CLOSEOUT_ENGINE="$engine" BOARD_CLOSEOUT_TIMEOUT_SEC="$timeout_s" \
    "$fake_stack/bin/last-stack-board-closeout-sweep" --board-cli "$hang_board" 2>/dev/null || true)"
  took=$(( $(date +%s) - start ))
  last="$(printf '%s\n' "$hout" | tail -n 1)"
  case "$last" in
    "board-closeout "*" error "*"flagged=engine-timeout-${timeout_s}s") : ;;
    *) echo "FAIL[$engine]: no terminal timeout line; last='$last'" >&2; fail=1 ;;
  esac
  if [ "$took" -ge "$hang_s" ]; then
    echo "FAIL[$engine]: timeout run took ${took}s; the watchdog or a child held the pipe" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "ok last-stack-board-closeout-failure-reasons"
