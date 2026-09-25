#!/usr/bin/env bash
# End-to-end reaper fixtures. Every external board/process/forge call is fake.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="${CARD_REAPER_TEST_RUNNER:-$ROOT/bin/last-stack-card-reaper-run}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/reaper-loom-guard.XXXXXX")
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/empty-stack"
export HOME="$tmp/home" LAST_STACK_ROOT="$tmp/empty-stack"
unset ROUTINES_RUN_DIR CARD_REAPER_RUN_DIR
export FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/kanban" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/calls"
case "$1" in
 show)
  test "$*" = 'show card-a --canonical --json' || { cat "$FIXTURE/card"; exit; }
  [ "$MODE" != card-missing ] || exit 1
  [ "$MODE" != card-invalid ] || { echo '{}'; exit; }
  count=$(cat "$FIXTURE/count")
  count=$((count+1)); printf '%s' "$count" > "$FIXTURE/count"
  if [ "$MODE" = stale-race ] && [ "$count" -gt 1 ]; then
    jq '.assignee="loom:new" | .body="PROGRESS: loom land-card exec=lx-new claimed"' "$FIXTURE/card" > "$FIXTURE/next"
    mv "$FIXTURE/next" "$FIXTURE/card"
  fi
  cat "$FIXTURE/card" ;;
 add) cat >> "$FIXTURE/writes" ;;
 move|rm) printf '%s\n' "$*" >> "$FIXTURE/writes" ;;
 *) exit 99 ;;
esac
FAKE
cat > "$tmp/bin/loom" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/loom-calls"
case "$MODE" in missing|unknown) exit 1 ;; esac
printf '%s\n' "$2"
case "$MODE" in parked) echo 'status: waiting' ;; terminal) echo 'status: succeeded' ;; *) echo 'status: running' ;; esac
echo 'state: IMPLEMENT'
if [ "$MODE" = mismatch ]; then echo 'context.card: "another-card"'; else echo 'context.card: "card-a"'; fi
echo 'node IMPLEMENT#2 running: -'
FAKE
cat > "$tmp/bin/git" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/git-calls"
exit 1
FAKE
cat > "$tmp/bin/ps" <<'FAKE'
#!/usr/bin/env bash
[ "$MODE" != ps-unknown ]
FAKE
chmod +x "$tmp/bin/kanban" "$tmp/bin/loom" "$tmp/bin/git" "$tmp/bin/ps"
for MODE in original resumed parked terminal unknown missing mismatch owner-only malformed branch-only malformed-branch card-missing card-invalid stale-todo stale-backlog stale-race recent recent-churn unknown-age ps-unknown dead; do
 export MODE
 export HOME="$tmp/home-$MODE"
 mkdir -p "$HOME"
 : > "$tmp/calls"; : > "$tmp/loom-calls"; : > "$tmp/git-calls"; : > "$tmp/writes"; printf 0 > "$tmp/count"
 jq -n '{slug:"card-a",column:"doing",assignee:"loom:worker",body:"PROGRESS: loom land-card exec=lx-original claimed",created_at:"2026-07-01T00:00:00Z",first_doing_at:"2026-07-01T00:00:00Z",updated_at:"2026-07-01T00:00:00Z"}' > "$tmp/card"
 case "$MODE" in
  owner-only) jq '.body=""' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card" ;;
  malformed) jq '.assignee="" | .body="PROGRESS: loom land-card exec=??? claimed"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card" ;;
  branch-only) jq '.assignee="" | .body="" | .branch="lx-original#IMPLEMENT"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card" ;;
  malformed-branch) jq '.assignee="" | .body="" | .branch="lx-broken"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card" ;;
  resumed) jq '.body += "\nBLOCKER: loom exec=lx-original parked: prior failure"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card" ;;
  stale-race|recent|recent-churn|unknown-age|ps-unknown|dead)
   jq '.assignee="" | .body="legacy work" | .first_doing_at="2026-07-20T10:00:00Z" | .updated_at="2026-07-20T11:31:08Z"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card"
   if [ "$MODE" = recent ] || [ "$MODE" = recent-churn ]; then jq '.updated_at="2026-07-20T13:20:00Z"' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card"; fi
   if [ "$MODE" = unknown-age ]; then jq 'del(.first_doing_at,.updated_at)' "$tmp/card" > "$tmp/next"; mv "$tmp/next" "$tmp/card"; fi ;;
 esac
 : > "$tmp/memory-$MODE"
 if [ "$MODE" = recent-churn ]; then echo 'prior rolled_back card-a rule=dead' > "$tmp/memory-$MODE"; fi
 cp "$tmp/memory-$MODE" "$tmp/memory-before"
 if [ "$MODE" = ps-unknown ]; then mkdir -p "$HOME/.fkanban/worktrees/card-a"; fi
 jq '[.]' "$tmp/card" > "$tmp/board"
 case "$MODE" in stale-todo|stale-backlog)
  column=${MODE#stale-}
  jq --arg column "$column" '.[0].column=$column | .[0].assignee="" | .[0].body=""' "$tmp/board" > "$tmp/next"; mv "$tmp/next" "$tmp/board" ;;
 esac
 "$RUNNER" --skip-preflight --board-json "$tmp/board" --memory "$tmp/memory-$MODE" --now 2026-07-20T13:31:08Z > "$tmp/out-$MODE"
 if [ "$MODE" = dead ]; then
  grep -q '^rolled_back card-a: doing dead claim >60m; age=2.0h$' "$tmp/out-$MODE"
  grep -q '^move card-a todo$' "$tmp/writes"
 else
  test ! -s "$tmp/writes"
  ! grep -Eq '^(add|move|rm) ' "$tmp/calls"
  cmp "$tmp/memory-$MODE" "$tmp/memory-before"
 fi
 ! grep -Eq 'worktree remove|commit|push' "$tmp/git-calls"
 test "$(wc -l < "$tmp/loom-calls")" -le 1
 echo "PASS $MODE"
done
