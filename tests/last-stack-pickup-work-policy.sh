#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-pickup-work-policy"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

chmod +x "$BIN"
PYTHONPYCACHEPREFIX="$tmp/pycache" python3 -m py_compile "$BIN"

action_of() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["action"])'
}

# Fresh slug with no history → work
printf '%s\n' '{"slug":"fresh-card"}' >"$tmp/fresh.json"
out="$("$BIN" --slug fresh-card --json --heartbeats "$tmp/empty.log" --since-min 0 --card-json "$tmp/fresh.json")"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "fresh slug should be work"; echo "$out"; exit 1
}

# Two timebox handoffs, no new commit → skip
cat >"$tmp/hb.log" <<'HB'
kanban-pickup 2026-08-20T10:00:00Z ok cards=1 worked=hot-slug result=in-flight-budget-handoff pr=none reason=command-timebox commit=aaa1111
kanban-pickup 2026-08-20T11:00:00Z ok cards=1 worked=hot-slug result=in-flight-budget-handoff pr=none reason=command-timebox commit=aaa1111
HB
printf '%s\n' '{"slug":"hot-slug"}' >"$tmp/hot.json"
out="$("$BIN" --slug hot-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/hot.json")"
test "$(printf '%s\n' "$out" | action_of)" = "skip" || {
  echo "two timeboxes should skip"; echo "$out"; exit 1
}

# Same two fires, new commit → work
out="$("$BIN" --slug hot-slug --json --heartbeats "$tmp/hb.log" --since-min 0 \
  --card-json "$tmp/hot.json" --head-sha bbb2222 --handoff-sha aaa1111)"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "new commit should reset WORK"; echo "$out"; exit 1
}

# pr_url → reconcile even with two timeboxes
printf '%s\n' '{"slug":"hot-slug","pr_url":"http://127.0.0.1:3300/EdgeVector/fold/pulls/1"}' >"$tmp/pr.json"
out="$("$BIN" --slug hot-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/pr.json")"
test "$(printf '%s\n' "$out" | action_of)" = "reconcile" || {
  echo "pr_url should reconcile"; echo "$out"; exit 1
}

# Distinct slug in same log remains claimable
printf '%s\n' '{"slug":"other-slug"}' >"$tmp/other.json"
out="$("$BIN" --slug other-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/other.json")"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "other slug should still be work"; echo "$out"; exit 1
}

echo ok
