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

# Bare pr_url with no liveness (unknown) → fail-closed reconcile, even with two timeboxes
printf '%s\n' '{"slug":"hot-slug","pr_url":"http://127.0.0.1:3300/EdgeVector/fold/pulls/1"}' >"$tmp/pr.json"
out="$("$BIN" --slug hot-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/pr.json")"
test "$(printf '%s\n' "$out" | action_of)" = "reconcile" || {
  echo "unknown pr_url should fail-closed reconcile"; echo "$out"; exit 1
}

# Distinct slug in same log remains claimable
printf '%s\n' '{"slug":"other-slug"}' >"$tmp/other.json"
out="$("$BIN" --slug other-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/other.json")"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "other slug should still be work"; echo "$out"; exit 1
}

# Closed-unmerged pr_url → work, not reconcile (the parent fkanban contract)
printf '%s\n' '{"slug":"dead-pr","pr_url":"https://github.com/acme/repo/pull/9","pr_liveness":{"state":"closed-unmerged","action":"work"}}' >"$tmp/dead.json"
out="$("$BIN" --slug dead-pr --json --heartbeats "$tmp/empty.log" --since-min 0 --card-json "$tmp/dead.json")"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "closed-unmerged pr_url should be work"; echo "$out"; exit 1
}

# Open pr_url fixture → reconcile
printf '%s\n' '{"slug":"open-pr","pr_url":"https://github.com/acme/repo/pull/2","pr_liveness":{"state":"open","action":"reconcile"}}' >"$tmp/open.json"
out="$("$BIN" --slug open-pr --json --heartbeats "$tmp/empty.log" --since-min 0 --card-json "$tmp/open.json")"
test "$(printf '%s\n' "$out" | action_of)" = "reconcile" || {
  echo "open pr_url should be reconcile"; echo "$out"; exit 1
}

# Merged pr_url fixture → closeout
printf '%s\n' '{"slug":"merged-pr","pr_url":"https://github.com/acme/repo/pull/3","pr_liveness":{"state":"merged","action":"closeout"}}' >"$tmp/merged.json"
out="$("$BIN" --slug merged-pr --json --heartbeats "$tmp/empty.log" --since-min 0 --card-json "$tmp/merged.json")"
test "$(printf '%s\n' "$out" | action_of)" = "closeout" || {
  echo "merged pr_url should be closeout"; echo "$out"; exit 1
}

# Cooldown skip still wins when there is no PR locator (closed-unmerged must not
# leak skip onto a dead PR; no-PR cooldown stays skip).
out="$("$BIN" --slug hot-slug --json --heartbeats "$tmp/hb.log" --since-min 0 --card-json "$tmp/hot.json")"
test "$(printf '%s\n' "$out" | action_of)" = "skip" || {
  echo "no-PR cooldown should still skip"; echo "$out"; exit 1
}

# Delegate to `kanban pickup work-policy` when a kanban bin is provided.
cat >"$tmp/kanban-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${KANBAN_STUB_ARGV}"
if [ "${1:-}" = pickup ] && [ "${2:-}" = "work-policy" ]; then
  cat "${KANBAN_STUB_JSON}"
  exit 0
fi
echo "unexpected: $*" >&2
exit 2
STUB
chmod +x "$tmp/kanban-stub"
cat >"$tmp/kanban-closed.json" <<'JSON'
{
  "slug": "dead-pr",
  "pr_url": "https://github.com/acme/repo/pull/9",
  "action": "work",
  "stale_pr_url": true,
  "pr_liveness": {
    "pr_url": "https://github.com/acme/repo/pull/9",
    "state": "closed-unmerged",
    "venue": "github",
    "action": "work",
    "note": "PR/CR is closed and unmerged; treat as no PR (fresh WORK)"
  }
}
JSON
export KANBAN_STUB_ARGV="$tmp/kanban-argv"
export KANBAN_STUB_JSON="$tmp/kanban-closed.json"
printf '%s\n' '{"slug":"dead-pr","pr_url":"https://github.com/acme/repo/pull/9"}' >"$tmp/dead-bare.json"
out="$("$BIN" --slug dead-pr --json --heartbeats "$tmp/empty.log" --since-min 0 \
  --card-json "$tmp/dead-bare.json" --kanban-bin "$tmp/kanban-stub")"
test "$(printf '%s\n' "$out" | action_of)" = "work" || {
  echo "kanban closed-unmerged delegate should be work"; echo "$out"; exit 1
}
grep -q 'pickup work-policy dead-pr --json' "$tmp/kanban-argv" || {
  echo "did not invoke kanban pickup work-policy"; cat "$tmp/kanban-argv"; exit 1
}

# Open report from kanban → reconcile
cat >"$tmp/kanban-open.json" <<'JSON'
{
  "slug": "open-pr",
  "pr_url": "https://github.com/acme/repo/pull/2",
  "action": "reconcile",
  "stale_pr_url": false,
  "pr_liveness": {
    "pr_url": "https://github.com/acme/repo/pull/2",
    "state": "open",
    "venue": "github",
    "action": "reconcile",
    "note": "PR/CR is open; reconcile (not pickup WORK)"
  }
}
JSON
KANBAN_STUB_JSON="$tmp/kanban-open.json"
export KANBAN_STUB_JSON
printf '%s\n' '{"slug":"open-pr","pr_url":"https://github.com/acme/repo/pull/2"}' >"$tmp/open-bare.json"
out="$("$BIN" --slug open-pr --json --heartbeats "$tmp/empty.log" --since-min 0 \
  --card-json "$tmp/open-bare.json" --kanban-bin "$tmp/kanban-stub")"
test "$(printf '%s\n' "$out" | action_of)" = "reconcile" || {
  echo "kanban open delegate should be reconcile"; echo "$out"; exit 1
}

echo ok
