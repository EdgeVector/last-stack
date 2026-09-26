#!/usr/bin/env bash
# Proof: board-closeout-sweep runs a targeted `loom reap --execution` for a
# loom-protected card whose walk is `running`, so a walk whose worker died is
# resumed on the next sweep instead of waiting for the hourly loom-reaper
# pass (2026-09-26: a MERGE on an already-merged PR sat 50 min with every
# lease expired). A live lease (`skip_live`) changes nothing, a parked walk is
# never reaped, and at most BOARD_CLOSEOUT_LOOM_REAP_MAX acting reaps run.
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
      '$(card_json walk-live 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-live-1 claimed')' \
      '$(card_json walk-dead-a 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-dead-a claimed')' \
      '$(card_json walk-dead-b 'Repo: EdgeVector/fold\nKind: pr\nPROGRESS: loom land-card exec=lx-dead-b claimed')' \
      '$(card_json walk-parked 'Repo: EdgeVector/fold\nKind: pr\nBLOCKER: loom exec=lx-park-1 parked: ci red')'
    ;;
  show) printf '{"slug":"%s","column":"doing"}\n' "\${2:-}" ;;
  add|tag|set|mark) : ;;
  move) printf '%s %s\n' "\${2:-}" "\${3:-}" >>"\${BOARD_MOVES:?}" ;;
  *) echo "unexpected: \$*" >&2; exit 2 ;;
esac
BOARD
chmod +x "$board"

cat >"$loom" <<'LOOM'
#!/usr/bin/env bash
case "${1:-}" in
  show)
    case "${2:-}" in
      lx-park-1) printf '%s\nstatus: parked\nstate: AWAIT_HUMAN\n' "$2" ;;
      *) printf '%s\nstatus: running\nstate: MERGE\n' "$2" ;;
    esac
    ;;
  reap)
    id="${3:-}"
    printf '%s %s\n' "$id" "$*" >>"${LOOM_REAPS:?}"
    case "$id" in
      lx-live-1) action=skip_live ;;
      *) action=resume ;;
    esac
    printf '{"dry_run":false,"outcomes":[{"exec_id":"%s","before":"running","after":"succeeded","action":"%s"}]}\n' "$id" "$action"
    ;;
  *) exit 2 ;;
esac
LOOM
chmod +x "$loom"
export BOARD_CLOSEOUT_LOOM_BIN="$loom"

for engine in node python3; do
  if [ "$engine" = node ] && ! command -v node >/dev/null 2>&1; then continue; fi
  moves="$tmp/moves.$engine"
  reaps="$tmp/reaps.$engine"
  : >"$moves"
  : >"$reaps"
  export BOARD_MOVES="$moves" LOOM_REAPS="$reaps" BOARD_CLOSEOUT_ENGINE="$engine" BOARD_CLOSEOUT_STATE_DIR="$tmp/state.$engine"
  out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
  fail() { echo "FAIL[$engine]: $*" >&2; echo "$out" >&2; cat "$reaps" >&2; exit 1; }
  [ -s "$moves" ] && fail "moved a loom-protected card"
  grep -q '^lx-park-1 ' "$reaps" && fail "reaped a parked walk"
  grep -q '^lx-live-1 .*--execution lx-live-1' "$reaps" || fail "no targeted reap for the running walk"
  printf '%s\n' "$out" | grep -q 'loom-claim-protected:walk-live:running' || fail "live walk flag changed"
  printf '%s\n' "$out" | grep -q 'walk-live:running+reap' && fail "flagged a reap on a live lease"
  acted="$(printf '%s\n' "$out" | grep '^board-closeout ' | grep -o 'walk-dead-[ab]:running+reap:resume' | wc -l | tr -d ' ')"
  [ "$acted" = 1 ] || fail "expected exactly 1 acting reap (budget 1), got $acted"
done

echo "ok last-stack-board-closeout-loom-reap"
