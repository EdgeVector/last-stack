#!/usr/bin/env bash
# Drive last-stack-kanban-decision-check against fixture brain files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-decision-check"
chmod +x "$BIN"
python3 -m py_compile "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# host-track publishes the helper next to file-pr (standalone + sibling call)
jq -e '
  .apps[]
  | select(.app == "last-stack")
  | any(.links[];
      .source == "bin/last-stack-kanban-decision-check"
      and .target == "$HOME/.local/bin/last-stack-kanban-decision-check")
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "last-stack registry does not publish last-stack-kanban-decision-check"

clear_dir="$tmp/clear"
honor_dir="$tmp/honor"
conflict_dir="$tmp/conflict"
mkdir -p "$clear_dir" "$honor_dir/get" "$conflict_dir/get"

printf '%s\n' '[]' >"$clear_dir/search.json"

cat >"$honor_dir/search.json" <<'EOF'
[{"slug":"decision-2026-07-02-standing-rule-every-card-gets-end","score":1.0,"type":"decision","title":"every card gets an end state","snippet":""}]
EOF
cat >"$honor_dir/get/decision-2026-07-02-standing-rule-every-card-gets-end.txt" <<'EOF'
[decision] decision-2026-07-02-standing-rule-every-card-gets-end
title:      every card gets an end state
---
Every card gets an end state at filing time.
EOF

cat >"$conflict_dir/search.json" <<'EOF'
[{"slug":"preference-kanban-no-trackers-no-human-gates","score":1.0,"type":"preference","title":"no trackers","snippet":""}]
EOF
cat >"$conflict_dir/get/preference-kanban-no-trackers-no-human-gates.txt" <<'EOF'
[preference] preference-kanban-no-trackers-no-human-gates
title:      no trackers
---
Do not file Kind: tracker.
EOF

body_ok="$tmp/body.md"
cat >"$body_ok" <<'EOF'
## GOAL
File pickup-ready Kind:pr cards.

## END STATE
Generators honor settled decisions.
EOF

run_json() {
  python3 "$BIN" --title "File pickup-ready cards" --kind pr --column todo \
    --fixture-dir "$1" --json <"$body_ok"
}

run_json "$clear_dir" >"$tmp/clear.json"
python3 - "$tmp/clear.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ok"] is True
assert p["verdict"] == "clear"
assert p["slugs"] == []
assert p["search_is_membership"] is False
assert "verdict: clear" in p["stamp"]
assert "slugs: none" in p["stamp"]
print("decision-check clear-fixture ok")
PY

run_json "$honor_dir" >"$tmp/honor.json"
python3 - "$tmp/honor.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ok"] is True
assert p["verdict"] == "honor"
assert "decision-2026-07-02-standing-rule-every-card-gets-end" in p["slugs"]
assert "decision-2026-07-02-standing-rule-every-card-gets-end" in p["point_gets"]
assert "verdict: honor" in p["stamp"]
print("decision-check honor-fixture ok")
PY

# inject replaces a prior stamp
stamped="$(python3 "$BIN" --title "File pickup-ready cards" --kind pr --column todo \
  --fixture-dir "$honor_dir" --inject <"$body_ok")"
printf '%s\n' "$stamped" | grep -q '## DECISION-CHECK' || fail "inject missing stamp"
printf '%s\n' "$stamped" | grep -q '## GOAL' || fail "inject dropped GOAL"
count="$(printf '%s\n' "$stamped" | grep -c '^## DECISION-CHECK' || true)"
[ "$count" -eq 1 ] || fail "inject left $count DECISION-CHECK sections"

# search is not membership: a listed slug that fails point-get is omitted
miss_dir="$tmp/miss"
mkdir -p "$miss_dir"
cat >"$miss_dir/search.json" <<'EOF'
[{"slug":"decision-does-not-exist","score":1.0,"type":"decision","title":"ghost","snippet":""}]
EOF
run_json "$miss_dir" >"$tmp/miss.json"
python3 - "$tmp/miss.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ok"] is True
assert p["verdict"] == "clear"
assert p["slugs"] == []
assert p["records"][0]["slug"] == "decision-does-not-exist"
assert p["records"][0]["got"] is False
print("decision-check search-is-not-membership ok")
PY

set +e
python3 "$BIN" --title "File a tracker" --kind tracker --column backlog \
  --fixture-dir "$conflict_dir" --json <"$body_ok" >"$tmp/conflict.json"
conflict_rc=$?
set -e
[ "$conflict_rc" -eq 2 ] || fail "tracker kind should exit 2, got $conflict_rc"
python3 - "$tmp/conflict.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["ok"] is False
assert p["verdict"] == "conflict"
assert p["conflicts"]
assert p["conflicts"][0]["slug"] == "preference-kanban-no-trackers-no-human-gates"
print("decision-check tracker-conflict ok")
PY

# papercut/reference hits must not become stamp slugs
other_dir="$tmp/other"
mkdir -p "$other_dir"
cat >"$other_dir/search.json" <<'EOF'
[{"slug":"papercut-example","score":1.0,"type":"papercut","title":"noise","snippet":""}]
EOF
run_json "$other_dir" >"$tmp/other.json"
python3 - "$tmp/other.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["verdict"] == "clear"
assert p["slugs"] == []
print("decision-check ignores non-decision types ok")
PY

echo "last-stack-kanban-decision-check tests ok"
