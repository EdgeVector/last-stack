#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/board-stub"
log="$tmp/actions.log"
todo_json="$tmp/todo.json"
helper="$ROOT/bin/last-stack-park-stuck-merge-poison-cards"

test -x "$helper"
bash -n "$helper"
if grep -nE '^[[:space:]]*mapfile ' "$helper" >/dev/null; then
  echo "helper must stay bash-3.2 portable (no mapfile builtin)" >&2
  exit 1
fi

cat > "$todo_json" <<'JSON'
[
  {
    "slug": "stuck-lastgit-last-stack-cr-ms6hdcc1-44bc",
    "title": "Clear stuck LastGit CR ms6hdcc1-44bc",
    "column": "todo",
    "kind": "pr",
    "tags": ["pipeline", "p0", "merge"],
    "milestone": "",
    "north_star": "",
    "body": "Kind: pr\nPriority: P0"
  },
  {
    "slug": "stuck-lastgit-brain-cr-closeddemo",
    "title": "Stuck CR already closed",
    "column": "todo",
    "kind": "pr",
    "tags": ["pipeline", "p0", "merge", "lastgit"],
    "milestone": "",
    "north_star": "",
    "body": "CR: cr-closeddemo\nlastgit://brain/cr/cr-closeddemo"
  },
  {
    "slug": "good-milestone-frontier-pr",
    "title": "Real frontier work",
    "column": "todo",
    "kind": "pr",
    "tags": ["pipeline"],
    "milestone": "ms-host-track-ops-hygiene-wave2",
    "north_star": "north-star-host-track",
    "body": "Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n\n## GOAL\nShip a real fix.\n\n## STEPS\n1. do work\n\n## VERIFY\nbash tests/x.sh"
  },
  {
    "slug": "ordinary-product-pr",
    "title": "Unrelated product",
    "column": "todo",
    "kind": "pr",
    "tags": ["product"],
    "milestone": "ms-something",
    "north_star": "ns-something",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\n\n## GOAL\nProduct work"
  }
]
JSON

cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
log="${STUB_LOG:?}"
todo="${STUB_TODO_JSON:?}"
echo "$*" >>"$log"
cmd="${1:-}"
shift || true
case "$cmd" in
  list)
    # list --column todo --json
    cat "$todo"
    ;;
  mark)
    # mark <slug> "<line>"
    echo "mark $*" >>"$log"
    ;;
  move)
    echo "move $*" >>"$log"
    ;;
  *)
    echo "unexpected: $cmd $*" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$stub"

# Fake lastgit: closeddemo is closed; everything else unknown/open.
fake_bin="$tmp/fakebin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lastgit" <<'LG'
#!/usr/bin/env bash
set -euo pipefail
# lastgit cr view <repo> <cr_id> --json
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  repo="${3:-}"; cr="${4:-}"
  if [ "$cr" = "cr-closeddemo" ] || [ "$cr" = "closeddemo" ]; then
    printf '%s\n' '{"state":"closed","merge_oid":"abc","repo":"'"$repo"'","cr_id":"'"$cr"'"}'
    exit 0
  fi
  printf '%s\n' '{"state":"open","repo":"'"$repo"'","cr_id":"'"$cr"'"}'
  exit 0
fi
echo "unexpected lastgit $*" >&2
exit 2
LG
chmod +x "$fake_bin/lastgit"

export PATH="$fake_bin:$PATH"
export STUB_LOG="$log"
export STUB_TODO_JSON="$todo_json"

out="$(
  STUB_LOG="$log" STUB_TODO_JSON="$todo_json" \
    "$helper" --board-cli "$stub" --json
)"

echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["parked"] >= 1, d
assert d["closed"] >= 1, d
parked=set(d["parked_slugs"])
closed=set(d["closed_slugs"])
assert "stuck-lastgit-last-stack-cr-ms6hdcc1-44bc" in parked, d
assert "stuck-lastgit-brain-cr-closeddemo" in closed, d
assert "good-milestone-frontier-pr" not in parked and "good-milestone-frontier-pr" not in closed, d
assert "ordinary-product-pr" not in parked and "ordinary-product-pr" not in closed, d
print("classify ok", d)
'

# Dry-run must not move
: >"$log"
dry="$(
  STUB_LOG="$log" STUB_TODO_JSON="$todo_json" \
    "$helper" --board-cli "$stub" --json --dry-run
)"
echo "$dry" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["dry_run"]==1 and d["parked"]>=1'
if grep -q '^move ' "$log"; then
  echo "dry-run must not move cards" >&2
  cat "$log" >&2
  exit 1
fi

# --skip-point-read parks closeddemo instead of closing
: >"$log"
skip="$(
  STUB_LOG="$log" STUB_TODO_JSON="$todo_json" \
    "$helper" --board-cli "$stub" --json --skip-point-read
)"
echo "$skip" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["closed"] == 0, d
assert "stuck-lastgit-brain-cr-closeddemo" in d["parked_slugs"], d
'

echo ok
