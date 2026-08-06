#!/usr/bin/env bash
# Offline fixtures for last-stack-forge-dead-trigger classify (+ help smoke).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-forge-dead-trigger"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

chmod +x "$bin"
"$bin" --help >/dev/null || fail "--help"
"$bin" classify --help >/dev/null || fail "classify --help"

# --- dead-trigger: empty status envelope + no tasks for head ---
cat >"$tmp/status-empty.json" <<'JSON'
{"url":"","state":"","statuses":[],"total_count":0,"commit_url":"","repository":{"id":1}}
JSON
cat >"$tmp/tasks-unrelated.json" <<'JSON'
{"workflow_runs":[
  {"id":1,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"completed"},
  {"id":2,"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"running"}
]}
JSON
head="cccccccccccccccccccccccccccccccccccccccc"
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-unrelated.json" \
  --min-age-secs 0 --json)"
verdict="$(printf '%s\n' "$out" | jq -r .verdict)"
rec="$(printf '%s\n' "$out" | jq -r .recommendation)"
[ "$verdict" = "dead-trigger" ] || fail "expected dead-trigger got $verdict ($out)"
[ "$rec" = "supersede" ] || fail "expected recommend=supersede got $rec"
st_n="$(printf '%s\n' "$out" | jq -r .status_total_count)"
tk_n="$(printf '%s\n' "$out" | jq -r .tasks_for_head)"
[ "$st_n" = "0" ] || fail "status_total_count=$st_n"
[ "$tk_n" = "0" ] || fail "tasks_for_head=$tk_n"

# --- has-runs via status total_count ---
cat >"$tmp/status-green.json" <<'JSON'
{"state":"success","statuses":[{"context":"Forge CI / ci-required","state":"success"}],"total_count":1}
JSON
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-green.json" \
  --tasks-json "$tmp/tasks-unrelated.json" \
  --json)"
[ "$(printf '%s\n' "$out" | jq -r .verdict)" = "has-runs" ] || fail "status path should be has-runs: $out"
[ "$(printf '%s\n' "$out" | jq -r .recommendation)" = "drive-normal" ] || fail "drive-normal expected"

# --- has-runs via matching actions task (empty status) ---
cat >"$tmp/tasks-match.json" <<JSON
{"workflow_runs":[
  {"id":9,"head_sha":"$head","status":"in_progress","name":"ci-required"}
]}
JSON
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-match.json" \
  --json)"
[ "$(printf '%s\n' "$out" | jq -r .verdict)" = "has-runs" ] || fail "tasks path should be has-runs: $out"
[ "$(printf '%s\n' "$out" | jq -r .tasks_for_head)" = "1" ] || fail "tasks_for_head"

# --- pending-wait: empty but head younger than min-age ---
now="$(date +%s)"
created=$((now - 30))
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-unrelated.json" \
  --min-age-secs 120 \
  --head-created-epoch "$created" \
  --json)"
[ "$(printf '%s\n' "$out" | jq -r .verdict)" = "pending-wait" ] || fail "expected pending-wait: $out"
[ "$(printf '%s\n' "$out" | jq -r .recommendation)" = "wait-then-reprobe" ] || fail "wait-then-reprobe"

# --- dead-trigger after age floor ---
created_old=$((now - 300))
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-unrelated.json" \
  --min-age-secs 120 \
  --head-created-epoch "$created_old" \
  --json)"
[ "$(printf '%s\n' "$out" | jq -r .verdict)" = "dead-trigger" ] || fail "aged empty should be dead-trigger: $out"

# --- tasks array (no workflow_runs wrapper) + commit_sha field ---
cat >"$tmp/tasks-array.json" <<JSON
[
  {"id":1,"commit_sha":"$head","status":"completed"}
]
JSON
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-array.json" \
  --json)"
[ "$(printf '%s\n' "$out" | jq -r .verdict)" = "has-runs" ] || fail "array tasks should match: $out"

# --- machine line (non-json) ---
line="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-unrelated.json")"
printf '%s\n' "$line" | grep -q 'verdict=dead-trigger' || fail "machine line: $line"
printf '%s\n' "$line" | grep -q 'recommend=supersede' || fail "machine recommend: $line"

# --- empty-commit is NOT the recommendation for dead-trigger ---
# (the note may mention empty-commit as the wrong heal; recommendation must be supersede)
out="$("$bin" classify --head-sha "$head" \
  --status-json "$tmp/status-empty.json" \
  --tasks-json "$tmp/tasks-unrelated.json" \
  --json)"
rec="$(printf '%s\n' "$out" | jq -r .recommendation)"
[ "$rec" = "supersede" ] || fail "supersede only, got recommendation=$rec"
printf '%s\n' "$rec" | grep -qi 'empty' && fail "recommendation must not mention empty-commit: $rec" || true

echo "ok"
