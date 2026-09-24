#!/usr/bin/env bash
# papercut-card-closeout-force-bypasses-host-track-deploy-gate-20260923
#
# On 2026-09-23 kanban refused `move <card> done` with
# `lifecycle_status_blocked ... deploy:host-track=missing`, and
# last-stack-card-closeout retried with --force, so the card reached done
# before host-track installed the merge. The helper must never pass --force
# past a deploy/lifecycle gate: it keeps the card out of done, marks the
# reason, and exits non-zero. --force stays only for a plain dependency block
# on a card that declares no Requires-Deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/forge-api" <<'EOF'
#!/usr/bin/env bash
case "$*" in *.merged*) echo true ;; *) echo '"abc123"' ;; esac
EOF
chmod +x "$tmp/forge-api"
export LAST_STACK_FORGE_API="$tmp/forge-api"

# Fake kanban. LG_MODE picks the refusal an unforced `move ... done` gets:
#   gate  -> lifecycle_status_blocked (kanban's real message shape)
#   dep   -> card_blocked (unfinished dependency)
# A forced move always lands, as the real kanban override does.
export LG_COL="$tmp/col" LG_LOG="$tmp/log" LG_MODE LG_BODY
board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    jq -n --arg slug "${2:-}" --arg col "$(cat "$LG_COL")" --arg body "$LG_BODY" \
      '{slug:$slug, column:$col, repo:"EdgeVector/widget", pr_url:"http://localhost:3300/EdgeVector/widget/pulls/7", branch:"", body:$body}'
    ;;
  add) exit 0 ;;
  mark) printf 'mark %s\n' "${3:-}" >>"$LG_LOG" ;;
  move)
    if [ "${3:-}" = done ]; then
      case " $* " in
        *" --force "*) echo "move-forced" >>"$LG_LOG"; echo done >"$LG_COL"; exit 0 ;;
      esac
      case "$LG_MODE" in
        gate)
          echo "lifecycle_status_blocked: Card \"${2:-}\" cannot move to \"done\" until required pipeline contexts succeed (deploy:host-track=missing)." >&2
          exit 1 ;;
        dep)
          echo "card_blocked: Card \"${2:-}\" is blocked by unfinished dependencies; pass --force to override." >&2
          exit 1 ;;
      esac
    fi
    printf '%s\n' "${3:-}" >"$LG_COL"
    ;;
  *) echo "unexpected board call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

gated_body=$'Repo: EdgeVector/widget\nKind: pr\nRequires-Deploy: host-track\nPROOF: passed unit tests\n'
plain_body=$'Repo: EdgeVector/widget\nKind: pr\nPROOF: passed unit tests\n'

run_case() {
  : >"$LG_LOG"
  echo doing >"$LG_COL"
  set +e
  out="$("$bin" lg-card --board-cli "$board" "$@" 2>&1)"
  rc=$?
  set -e
}

fail() { echo "FAIL: $1" >&2; printf '%s\n' "$out" >&2; cat "$LG_LOG" >&2; exit 1; }

# 1) Lifecycle gate refusal: no --force, card stays in doing, reason marked, rc!=0.
LG_MODE=gate LG_BODY="$gated_body"
run_case
[ "$rc" -ne 0 ] || fail "gate refusal must exit non-zero"
[ "$(cat "$LG_COL")" = doing ] || fail "gate refusal must keep the card in doing"
! grep -q move-forced "$LG_LOG" || fail "gate refusal must never retry with --force"
grep -q 'mark CLOSEOUT-DEFERRED: lifecycle gate refused done' "$LG_LOG" || fail "gate refusal must mark the reason"
grep -q 'deploy:host-track=missing' "$LG_LOG" || fail "the mark must carry kanban's gate detail"
printf '%s\n' "$out" | grep -q 'FAILED lifecycle-gate-refused' || fail "missing FAILED line"

# 2) The caller's --force does not override a lifecycle gate either.
run_case --force
[ "$rc" -ne 0 ] || fail "caller --force must not pass a lifecycle gate"
[ "$(cat "$LG_COL")" = doing ] || fail "caller --force must keep the card in doing"
! grep -q move-forced "$LG_LOG" || fail "caller --force reached a forced move past the gate"

# 3) Dependency block on a card without Requires-Deploy: forced retry lands.
LG_MODE=dep LG_BODY="$plain_body"
run_case
[ "$rc" -eq 0 ] || fail "dependency block without a deploy gate must still close (rc=$rc)"
[ "$(cat "$LG_COL")" = done ] || fail "dependency block retry must reach done"
grep -q move-forced "$LG_LOG" || fail "dependency block must use the forced retry"

# 4) Dependency block on a deploy-gated card: a forced move would skip the
#    deploy gate, so refuse.
LG_MODE=dep LG_BODY="$gated_body"
run_case
[ "$rc" -ne 0 ] || fail "dependency block on a Requires-Deploy card must not force"
[ "$(cat "$LG_COL")" = doing ] || fail "deploy-gated dependency block must keep the card in doing"
! grep -q move-forced "$LG_LOG" || fail "deploy-gated dependency block reached a forced move"

echo "ok last-stack-card-closeout-lifecycle-gate"
