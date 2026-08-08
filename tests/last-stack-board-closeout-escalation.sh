#!/usr/bin/env bash
# Proof: a closeout that can never succeed must get LOUD, not repeat in silence.
#
# 2026-08-08: cloud-sync-mutation-log-capture-never-wired-to-write-path was
# merged AND deployed, but its Requires-Deploy gate could never resolve, so the
# sweep flagged close-failed on it every few minutes for 10h and nothing said so
# anywhere a human looks. Brain:
# papercut-deploy-pipeline-gate-has-no-producer-for-non-lastgit-repos
#
# Asserts, on both engines (node + python3 fallback):
#   1. below the threshold  → close-failed only, no escalation, no board stamp
#   2. at the threshold     → close-failed-escalated + ONE CLOSE-FAILED-REPEATED
#                             stamp carrying the real failure text
#   3. past the threshold   → still flagged, but NOT stamped again
#   4. transient failures   → never count toward the streak
#   5. card leaves `doing`  → streak cleared
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A stack dir with a closeout that always refuses for a NON-transient reason —
# exactly the unsatisfiable-gate shape.
mkstack() {
  local dir="$1" mode="$2"
  mkdir -p "$dir/bin"
  cp "$sweep" "$dir/bin/last-stack-board-closeout-sweep"
  chmod +x "$dir/bin/last-stack-board-closeout-sweep"
  if [ "$mode" = transient ]; then
    cat >"$dir/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "service_timeout: board point read failed" >&2
exit 1
EOF
  else
    cat >"$dir/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "last-stack-card-closeout: deploy gate pending slug=stuck-card repo=fold requires=deploy-pipeline status=missing reason=deploy log missing" >&2
exit 1
EOF
  fi
  chmod +x "$dir/bin/last-stack-card-closeout"
}

mkboard() {
  local path="$1" column="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "stuck-card",
    "title": "merged, deployed, gate unsatisfiable",
    "column": "$column",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://brain/cr/cr-ms8mz1xt-981a",
    "branch": "kanban/stuck-card",
    "repo": "EdgeVector/brain",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/brain\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  mark)
    printf '%s\n' "\${3:-}" >>"\${BOARD_MARKS:?}"
    ;;
  move)
    printf '%s %s\n' "\${2:-}" "\${3:-}" >>"\${BOARD_MOVES:?}"
    ;;
  add|tag)
    : ;;
  *)
    echo "unexpected: \$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$path"
}

# `stuck-card` carries a MERGED CR, so the sweep tries to close it every pass.
binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  echo '{"cr":{"state":"merged","id":"cr-ms8mz1xt-981a","merge_oid":"abc123"}}'
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/lastgit"

node_free_path="$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin"

for engine in node python3; do
  if [ "$engine" = python3 ]; then
    if ! env PATH="$node_free_path" sh -c 'command -v python3 >/dev/null'; then
      echo "skip: no python3 on the node-free PATH" >&2
      continue
    fi
    if env PATH="$node_free_path" sh -c 'command -v node >/dev/null'; then
      echo "skip: could not build a node-free PATH for the fallback engine" >&2
      continue
    fi
    engine_path="$binwrap:$node_free_path"
  else
    command -v node >/dev/null || { echo "skip: no node" >&2; continue; }
    engine_path="$binwrap:$PATH"
  fi

  stack="$tmp/stack.$engine"
  mkstack "$stack" hard
  board="$tmp/board.$engine"
  mkboard "$board" doing
  state_dir="$tmp/state.$engine"
  marks="$tmp/marks.$engine"
  moves="$tmp/moves.$engine"
  : >"$marks"
  : >"$moves"

  pass() {
    env PATH="$engine_path" \
      BOARD_MARKS="$marks" BOARD_MOVES="$moves" \
      BOARD_CLOSEOUT_STATE_DIR="$state_dir" \
      "$1/bin/last-stack-board-closeout-sweep" \
      --board-cli "$2" --grace-min 1 --max-park-hours 999999 \
      --escalate-after 3 --max-actions 20 2>&1 || true
  }

  # 1. First two passes: failing, but not yet loud.
  for i in 1 2; do
    out="$(pass "$stack" "$board")"
    echo "$out" | grep -q 'close-failed:stuck-card' || {
      echo "FAIL[$engine] pass $i: expected close-failed: $out" >&2
      exit 1
    }
    if echo "$out" | grep -q 'close-failed-escalated'; then
      echo "FAIL[$engine] pass $i: escalated before the threshold: $out" >&2
      exit 1
    fi
  done
  [ ! -s "$marks" ] || {
    echo "FAIL[$engine]: board was stamped before the threshold:" >&2
    cat "$marks" >&2
    exit 1
  }

  # 2. Third pass crosses --escalate-after: flagged AND stamped once, with the
  #    real reason in the stamp so the card says what is actually wrong.
  out="$(pass "$stack" "$board")"
  echo "$out" | grep -q 'close-failed-escalated:stuck-card' || {
    echo "FAIL[$engine]: expected escalation on pass 3: $out" >&2
    exit 1
  }
  [ "$(wc -l <"$marks")" -eq 1 ] || {
    echo "FAIL[$engine]: expected exactly one board stamp:" >&2
    cat "$marks" >&2
    exit 1
  }
  grep -q 'CLOSE-FAILED-REPEATED' "$marks" || {
    echo "FAIL[$engine]: stamp missing its marker:" >&2
    cat "$marks" >&2
    exit 1
  }
  grep -q 'deploy gate pending' "$marks" || {
    echo "FAIL[$engine]: stamp did not carry the failure reason:" >&2
    cat "$marks" >&2
    exit 1
  }

  # 3. Further passes stay flagged but must not re-stamp the card every pass.
  out="$(pass "$stack" "$board")"
  echo "$out" | grep -q 'close-failed:stuck-card' || {
    echo "FAIL[$engine]: expected the failure to keep being reported: $out" >&2
    exit 1
  }
  [ "$(wc -l <"$marks")" -eq 1 ] || {
    echo "FAIL[$engine]: card was stamped more than once:" >&2
    cat "$marks" >&2
    exit 1
  }

  # 4. A transient board failure is not evidence the CARD is stuck — it must
  #    never accumulate a streak, however many times it happens.
  tstack="$tmp/tstack.$engine"
  mkstack "$tstack" transient
  tstate="$tmp/tstate.$engine"
  tmarks="$tmp/tmarks.$engine"
  : >"$tmarks"
  for i in 1 2 3 4; do
    tout="$(env PATH="$engine_path" \
      BOARD_MARKS="$tmarks" BOARD_MOVES="$moves" \
      BOARD_CLOSEOUT_STATE_DIR="$tstate" \
      "$tstack/bin/last-stack-board-closeout-sweep" \
      --board-cli "$board" --grace-min 1 --max-park-hours 999999 \
      --escalate-after 3 --max-actions 20 2>&1 || true)"
    if echo "$tout" | grep -q 'close-failed-escalated'; then
      echo "FAIL[$engine]: transient failure escalated on pass $i: $tout" >&2
      exit 1
    fi
  done
  [ ! -s "$tmarks" ] || {
    echo "FAIL[$engine]: transient failure stamped the board:" >&2
    cat "$tmarks" >&2
    exit 1
  }

  # 5. Once the card leaves `doing`, its streak is cleared — a later, unrelated
  #    failure must start from zero rather than escalating immediately.
  gone_board="$tmp/gone-board.$engine"
  mkboard "$gone_board" done
  pass "$stack" "$gone_board" >/dev/null
  : >"$marks"
  out="$(pass "$stack" "$board")"
  if echo "$out" | grep -q 'close-failed-escalated'; then
    echo "FAIL[$engine]: streak survived the card leaving doing: $out" >&2
    exit 1
  fi
  [ ! -s "$marks" ] || {
    echo "FAIL[$engine]: re-stamped after the streak should have reset:" >&2
    cat "$marks" >&2
    exit 1
  }
done

echo "ok last-stack-board-closeout-escalation"
