#!/usr/bin/env bash
# Both engines must distinguish future rollout requirements from current waits.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stack/bin"
cp "$ROOT/bin/last-stack-board-closeout-sweep" "$tmp/stack/bin/"
export BOARD_CLOSEOUT_STATE_DIR="$tmp/state"
export BOARD_FIXTURE="$tmp/cards.json"
export BOARD_MOVES="$tmp/moves"
cat > "$BOARD_FIXTURE" <<'JSON'
[
 {"slug":"future-rollout","column":"doing","updated_at":"2099-01-01T00:00:00Z","branch":"kanban/future-rollout","assignee":"worker","body":"Requires-Deploy: safe-upgrade\n## GOAL\nImplement bounded reads.\n## END STATE\nAfter implementation, safe-upgrade and LIVE PROOF are required. Work is pending.\n"},
 {"slug":"superseded-wait","column":"doing","updated_at":"2099-01-01T00:00:00Z","branch":"kanban/superseded-wait","body":"PARKED: awaiting deploy; LIVE PROOF pending\nPROGRESS: Source work resumed. Fix the read path first.\n"},
 {"slug":"current-note-wait","column":"doing","updated_at":"2099-01-01T00:00:00Z","body":"PROGRESS: Source work resumed.\nHANDOFF: Code is complete; awaiting deploy.\n"},
 {"slug":"tagged-wait","column":"doing","tags":["awaiting-deploy"],"body":"Requires-Deploy: safe-upgrade\n"},
 {"slug":"merged-gated","column":"doing","repo":"EdgeVector/fold","pr_url":"http://localhost:3300/EdgeVector/fold/pulls/4242","body":"Requires-Deploy: safe-upgrade\n## END STATE\nThe installed binary runs the new code.\n"},
 {"slug":"open-tagged","column":"doing","repo":"EdgeVector/fold","pr_url":"http://localhost:3300/EdgeVector/fold/pulls/4243","tags":["awaiting-deploy"],"body":"Requires-Deploy: safe-upgrade\n"}
]
JSON
cat > "$tmp/board" <<'SH'
#!/usr/bin/env bash
case "$1" in
 list) cat "$BOARD_FIXTURE" ;;
 show) printf '{"column":"doing"}\n' ;;
 move) printf '%s %s\n' "$2" "$3" >> "$BOARD_MOVES" ;;
 add|tag|set|mark) : ;;
 *) exit 2 ;;
esac
SH
cat > "$tmp/stack/bin/last-stack-forge-api" <<'SH'
#!/usr/bin/env bash
case "$*" in
 *4242*) printf '{"state":"closed","merged":true,"merge_commit_sha":"abcdef0123456789"}\n' ;;
 *) printf '{"state":"open","merged":false}\n' ;;
esac
SH
cat > "$tmp/stack/bin/last-stack-card-closeout" <<'SH'
#!/usr/bin/env bash
echo 'required deployment proof is incomplete' >&2
exit 1
SH
# No fixture may inspect live process arguments or consult shared services.
for command in ps lastgit brain kanban fkanban; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/stack/bin/$command"
done
chmod +x "$tmp/board" "$tmp/stack/bin/"*
for engine in node python3; do
  : > "$BOARD_MOVES"
  BOARD_CLOSEOUT_ENGINE="$engine" "$tmp/stack/bin/last-stack-board-closeout-sweep" \
    --board-cli "$tmp/board" --max-actions 20 > "$tmp/$engine.out"
  for slug in future-rollout superseded-wait open-tagged; do
    if grep -q "^$slug " "$BOARD_MOVES"; then
      echo "FAIL $engine moved active source card $slug" >&2
      cat "$BOARD_MOVES" >&2
      exit 1
    fi
  done
  for slug in current-note-wait tagged-wait merged-gated; do
    grep -q "^$slug backlog$" "$BOARD_MOVES" || {
      echo "FAIL $engine did not preserve current wait/merged gate for $slug" >&2
      cat "$tmp/$engine.out" >&2
      exit 1
    }
  done
done
echo 'ok last-stack-board-closeout-active-source (node and python3)'
