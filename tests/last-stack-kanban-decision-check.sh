#!/usr/bin/env bash
# Drive last-stack-kanban-decision-check against fixture brain files.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/python-cache.sh"  # writable py_compile cache

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

# Search candidates with unsupported types still get a point-read. The
# point-read type, not typed search metadata, controls the stamp set.
other_dir="$tmp/other"
mkdir -p "$other_dir/get"
cat >"$other_dir/search.json" <<'EOF'
[{"slug":"papercut-example","score":1.0,"type":"papercut","title":"noise","snippet":""}]
EOF
cat >"$other_dir/get/papercut-example.txt" <<'EOF'
[papercut] papercut-example
title:      noise
---
This record must not enter the decision stamp.
EOF
run_json "$other_dir" >"$tmp/other.json"
python3 - "$tmp/other.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["verdict"] == "clear"
assert p["slugs"] == []
assert p["point_gets"] == ["papercut-example"]
print("decision-check ignores non-decision types ok")
PY

# Candidate discovery uses the untyped hybrid ask path. A fake brain records
# the argv and returns a valid point-get response, so this test rejects typed
# enumeration on the preferred path.
argv_log="$tmp/argv.log"
typed_probe="$tmp/typed-probe"
cat >"$typed_probe" <<'PROBE'
#!/bin/sh
printf '%s\n' "$*" >>"$ARGV_LOG"
if [ "$1" = ask ] || [ "$1" = search ]; then
  printf '%s\n' '[{"slug":"decision-probe","type":"decision"}]'
else
  printf '%s\n' '[decision] decision-probe'
fi
PROBE
chmod +x "$typed_probe"
ARGV_LOG="$argv_log" python3 "$BIN" --title "untyped search probe" --kind pr --column todo \
  --brain "$typed_probe" --json <"$body_ok" >"$tmp/untyped.json"
grep -q '^ask .*--limit .*--json$' "$argv_log" \
  || fail "decision search must use untyped hybrid ask"
if grep -q -- '^ask .*--type' "$argv_log"; then
  fail "decision ask must not enumerate brain types"
fi
python3 - "$tmp/untyped.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["verdict"] == "honor"
assert p["point_gets"] == ["decision-probe"]
print("decision-check untyped-hybrid-search ok")
PY

# One incomplete type index degrades the candidate set but does not close the
# gate. The other type still supplies a point-read candidate.
degraded_log="$tmp/degraded.log"
degraded_probe="$tmp/degraded-probe"
cat >"$degraded_probe" <<'PROBE'
#!/bin/sh
printf '%s\n' "$*" >>"$ARGV_LOG"
case "$*" in
  *'--type design '*)
    printf '%s\n' 'design index incomplete' >&2
    exit 1
    ;;
  *)
    case "$1" in
      search)
        printf '%s\n' '[{"slug":"decision-probe","type":"decision"}]'
        ;;
      *)
        printf '%s\n' '[decision] decision-probe'
        ;;
    esac
    ;;
esac
PROBE
chmod +x "$degraded_probe"
ARGV_LOG="$degraded_log" python3 "$BIN" --title "degraded search probe" --kind pr --column todo \
  --brain "$degraded_probe" --json <"$body_ok" >"$tmp/degraded.json"
python3 - "$tmp/degraded.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["verdict"] == "honor"
assert p["degraded_types"] == ["design"]
assert p["search_failures"]["design"] == "design index incomplete"
print("decision-check degraded-type search ok")
PY

# a stdin that never delivers a byte must fail fast, not deadlock the caller
set +e
sleep 30 | LAST_STACK_DECISION_CHECK_STDIN_TIMEOUT=2 python3 "$BIN" \
  --title "wedge probe" --kind pr --column todo \
  --fixture-dir "$clear_dir" --json >"$tmp/wedge.out" 2>"$tmp/wedge.err"
wedge_rc=$?
set -e
[ "$wedge_rc" -eq 2 ] || fail "never-delivering stdin should exit 2, got $wedge_rc"
grep -q "no card body on stdin" "$tmp/wedge.err" \
  || fail "stdin timeout must name the cause"
grep -q "< card.md" "$tmp/wedge.err" || fail "stdin timeout must print the fix"
echo "decision-check stdin-never-delivers fails fast ok"

# an immediate EOF is a legitimate empty body, never the timeout path
set +e
LAST_STACK_DECISION_CHECK_STDIN_TIMEOUT=2 python3 "$BIN" \
  --title "empty body" --kind pr --column todo \
  --fixture-dir "$clear_dir" --json </dev/null >"$tmp/eof.json" 2>"$tmp/eof.err"
eof_rc=$?
set -e
[ "$eof_rc" -eq 0 ] || fail "empty stdin should exit 0, got $eof_rc ($(cat "$tmp/eof.err"))"
echo "decision-check empty-stdin still passes ok"

# a brain that never answers must retry once, then fail with one readable line
# instead of an unhandled TimeoutExpired traceback. 2026-09-05: a slow node made
# every `brain search` here exceed the old hard-coded 60 s, and the traceback
# blocked all Kind:pr filing fleet-wide.
slow_bin="$tmp/slow-brain"
cat >"$slow_bin" <<'SLOW'
#!/bin/sh
sleep 30
SLOW
chmod +x "$slow_bin"
set +e
LAST_STACK_DECISION_CHECK_BRAIN_TIMEOUT=1 \
LAST_STACK_DECISION_CHECK_BRAIN_RETRY_TIMEOUT=1 \
python3 "$BIN" --title "slow node probe" --kind pr --column todo \
  --brain "$slow_bin" >"$tmp/slow.out" 2>"$tmp/slow.err" <<'BODY'
## GOAL
probe
BODY
slow_rc=$?
set -e
[ "$slow_rc" -eq 1 ] || fail "brain timeout should exit 1, got $slow_rc"
grep -q "Traceback" "$tmp/slow.err" \
  && fail "brain timeout must not print a Python traceback"
grep -q "timed out twice" "$tmp/slow.err" \
  || fail "brain timeout must say it retried: $(cat "$tmp/slow.err")"
echo "decision-check brain-timeout retries then fails readably ok"

echo "last-stack-kanban-decision-check tests ok"
