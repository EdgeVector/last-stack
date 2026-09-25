#!/usr/bin/env bash
# Proof: board-closeout-sweep does not roll back a doing card that a live
# Loom land-card execution holds. Loom keeps the PR in its execution context
# and never stamps pr_url on the card, so the no-PR zombie path used to move
# the card to todo while the execution waited on CI for an open PR
# (lastdb-storage-recovery-rollback, 2026-09-25). A terminal execution still
# rolls back so pickup can start a fresh one; an unreadable execution is held.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/board"
loom="$tmp/loom"

card_json() {
  # slug, body
  printf '{"slug":"%s","title":"t","column":"doing","position":"1","assignee":"","tags":[],"pr_url":"","branch":"","repo":"EdgeVector/fold","updated_at":"2020-01-01T00:00:00.000Z","body":"%s"}' "$1" "$2"
}

cat >"$board" <<BOARD
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    printf '[%s,%s,%s,%s]\n' \
      '$(card_json loom-live 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-live-1 claimed')' \
      '$(card_json loom-terminal 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-done-1 claimed')' \
      '$(card_json loom-unreadable 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-gone-1 claimed')' \
      '$(card_json plain-zombie 'Repo: EdgeVector/fold\nKind: pr')'
    ;;
  show)
    echo "show unavailable" >&2; exit 3 ;;
  add|tag|set|mark) : ;;
  move) printf '%s %s\n' "\${2:-}" "\${3:-}" >>"\${BOARD_MOVES:?}" ;;
  *) echo "unexpected: \$*" >&2; exit 2 ;;
esac
BOARD
chmod +x "$board"

cat >"$loom" <<'LOOM'
#!/usr/bin/env bash
[ "${1:-}" = show ] || exit 2
case "${2:-}" in
  lx-live-1) printf 'lx-live-1\nstatus: running\nstate: WAIT_CI\n' ;;
  lx-done-1) printf 'lx-done-1\nstatus: failed\nstate: IMPLEMENT\n' ;;
  *) echo "execution not found" >&2; exit 1 ;;
esac
LOOM
chmod +x "$loom"
export BOARD_CLOSEOUT_LOOM_BIN="$loom"

for engine in node python3; do
  if [ "$engine" = node ] && ! command -v node >/dev/null 2>&1; then continue; fi
  moves="$tmp/moves.$engine"
  : >"$moves"
  export BOARD_MOVES="$moves" BOARD_CLOSEOUT_ENGINE="$engine" BOARD_CLOSEOUT_STATE_DIR="$tmp/state.$engine"
  out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
  fail() { echo "FAIL[$engine]: $*" >&2; echo "$out" >&2; cat "$moves" >&2; exit 1; }
  grep -q '^loom-live ' "$moves" && fail "moved a card a running Loom execution holds"
  grep -q '^loom-unreadable ' "$moves" && fail "moved a card whose Loom execution is unreadable"
  grep -q '^loom-terminal todo' "$moves" || fail "expected loom-terminal rolled back to todo"
  grep -q '^plain-zombie todo' "$moves" || fail "expected plain-zombie rolled back to todo"
  printf '%s\n' "$out" | grep -q 'loom-claim-protected:loom-live:running' || fail "missing loom-claim-protected flag"
  printf '%s\n' "$out" | grep -q 'loom-claim-protected:loom-unreadable:unknown' || fail "missing unknown flag"
done

echo "ok last-stack-board-closeout-loom-claim"
