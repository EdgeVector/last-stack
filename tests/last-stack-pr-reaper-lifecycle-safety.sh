#!/usr/bin/env bash
# Regression tests for pr-reaper lifecycle safety gaps.
#
# Two fixes:
# 1. PR reaper does not close a draft PR or requeue its card if the card is
#    currently owned by an active Loom recovery.
# 2. An empty Forge ledger read is distinguished from a genuinely empty reap
#    plan; the reaper surfaces an error instead of silently reaping nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LEDGER="$ROOT/bin/last-stack-pipeline-forge-pr-ledger"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

fx="$tmp/forge"
mkdir -p "$fx" "$tmp/brain" "$tmp/board"

# ── fake forge ───────────────────────────────────────────────────────────────
cat >"$tmp/forge-api" <<'SH'
#!/usr/bin/env bash
path="$1"
key="$(printf '%s' "$path" | tr '/?&=' '____')"
f="$FAKE_FORGE_DIR/$key.json"
if [ -f "$f" ]; then cat "$f"; exit 0; fi
echo "HTTP 404 GET $path" >&2
exit 1
SH
chmod +x "$tmp/forge-api"

# ── fake kanban ──────────────────────────────────────────────────────────────
cat >"$tmp/kanban-bin" <<'SH'
#!/usr/bin/env bash
db="$FAKE_BOARD_DIR"
case "$1" in
  show)
    slug="$2"
    if [ -f "$db/$slug.json" ]; then
      cat "$db/$slug.json"; exit 0
    fi
    echo "{\"error\":\"card not found\"}" >&2; exit 1 ;;
  *)
    echo "unexpected kanban call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/kanban-bin"

# ── fake guard ───────────────────────────────────────────────────────────────
cat >"$tmp/guard-bin" <<'SH'
#!/usr/bin/env bash
# All over-age PRs get close-ok unless their number ends in "7" (owned) or "8" (indeterminate).
pr_num="$4"
case "$pr_num" in
  *7) echo '{"verdict":"close-ok","reason":"test"}' ;;
  *8) echo '{"verdict":"indeterminate","reason":"test"}' ;;
  *) echo '{"verdict":"close-ok","reason":"test"}' ;;
esac
SH
chmod +x "$tmp/guard-bin"

export FAKE_FORGE_DIR="$fx" FAKE_BOARD_DIR="$tmp/board"
export LAST_STACK_FORGE_API="$tmp/forge-api"
export LAST_STACK_CLOSE_GUARD="$tmp/guard-bin"
export LAST_STACK_PR_LEDGER_NOW="2026-09-25T12:00:00Z"

put() { key="$(printf '%s' "$1" | tr '/?&=' '____')"; cat >"$fx/$key.json"; }

# ── Setup: one repo with PRs ──────────────────────────────────────────────────
R=EdgeVector/last-stack
put "repos/$R/branch_protections" <<'J'
[{"rule_name":"main","enable_status_check":true,"status_check_contexts":["Forge CI / ci-required (pull_request)"]}]
J

put "repos/$R/branches/main" <<'J'
{"commit":{"id":"base1"}}
J

put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-25T11:00:00Z"}]}
J

pulls_open() {
  local first=1
  printf '['
  for n in "$@"; do
    [ "$first" = 1 ] || printf ','
    first=0
    # PR 6 and 7: owned by loom recovery; PR 8: owned by actual card; PR 9: no card owner
    printf '{"number":%s,"state":"open","title":"pr%s","mergeable":true,"created_at":"2026-09-25T10:00:00Z","updated_at":"2026-09-25T10:00:00Z","head":{"ref":"kanban/card%s","sha":"head%s"},"base":{"ref":"main"}}' "$n" "$n" "$n" "$n"
  done
  printf ']\n'
}

# Test 1: PR with owned card (in doing, fresh update)
pulls_open 6 7 | put "repos/$R/pulls?state=open&limit=50"
for n in 6 7; do
  put "repos/$R/commits/head$n/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","created_at":"2026-09-25T10:10:00Z"}]}
J
  put "repos/$R/pulls/$n" <<J
{"number":$n,"state":"open","title":"pr$n","mergeable":true,"created_at":"2026-09-25T10:00:00Z","updated_at":"2026-09-25T10:00:00Z","head":{"ref":"kanban/card$n","sha":"head$n"},"base":{"ref":"main"}}
J
done

# ── Card 6: in doing, fresh update (owned by live Loom recovery) ──────────────
cat >"$tmp/board/card6.json" <<'J'
{
  "slug": "card6",
  "column": "doing",
  "assignee": "test-worker",
  "updated_at": "2026-09-25T11:50:00Z",
  "body": "PR 6 test card"
}
J

# ── Test 1: owned card should NOT be in may_close ────────────────────────────
echo "TEST 1: PR with owned card is not closeable"
"$LEDGER" reap-plan --repo "$R" --reap-age-min 60 --kanban-bin "$tmp/kanban-bin" --owner-fresh-min 120 --json >"$tmp/plan.json" 2>"$tmp/plan.err" || true

# PR 6 should have owned_by set and may_close should be false
if jq -e '[.reap_plan[] | select(.number==6)][0] | .owned_by=="card6" and .may_close==false' "$tmp/plan.json" >/dev/null 2>&1; then
  echo "✓ PR 6: owned_by=card6, may_close=false (correct)"
else
  echo "✗ FAIL: PR 6 should have owned_by=card6 and may_close=false"
  cat "$tmp/plan.json"
  exit 1
fi

# Test 2: PR without owned card should be closeable
echo ""
echo "TEST 2: PR without owned card is closeable"
# PR 7 has no card in doing (doesn't exist), so should be closeable
if jq -e '[.reap_plan[] | select(.number==7)][0] | .owned_by=="" and .may_close==true' "$tmp/plan.json" >/dev/null 2>&1; then
  echo "✓ PR 7: owned_by=\"\", may_close=true (correct)"
else
  echo "✗ FAIL: PR 7 should have owned_by=\"\" and may_close=true"
  cat "$tmp/plan.json"
  exit 1
fi

# Test 3: Empty reap plan must be distinguished from read failure
echo ""
echo "TEST 3: Empty Forge ledger read is distinguished from valid empty plan"

# 3a: Valid empty plan (no unreadable repos, no over-age PRs)
echo "3a: Valid empty plan (no over-age PRs)"
put "repos/$R/pulls?state=open&limit=50" <<'J'
[]
J

"$LEDGER" reap-plan --repo "$R" --reap-age-min 60 --json >"$tmp/plan2.json" 2>"$tmp/plan2.err" || true

if jq -e '.plan_valid==true and (.reap_plan | length)==0' "$tmp/plan2.json" >/dev/null 2>&1; then
  echo "✓ Empty reap_plan with plan_valid=true (valid empty plan)"
else
  echo "✗ FAIL: plan_valid should be true for genuinely empty plan"
  cat "$tmp/plan2.json"
  exit 1
fi

# 3b: Invalid plan (repo unreadable, marked in unreadable list)
echo ""
echo "3b: Read failure is marked as invalid"
# Simply try to read a repo that doesn't have fixtures set up
"$LEDGER" reap-plan --repo EdgeVector/last-stack --repo EdgeVector/other --reap-age-min 60 --json >"$tmp/plan3.json" 2>"$tmp/plan3.err" || true

if jq -e '.plan_valid==false and (.unreadable | length)>0' "$tmp/plan3.json" >/dev/null 2>&1; then
  echo "✓ plan_valid=false when unreadable repos exist (error condition)"
else
  echo "✗ FAIL: plan_valid should be false when repos are unreadable"
  jq '.plan_valid, (.unreadable | length)' "$tmp/plan3.json"
  cat "$tmp/plan3.json" | head -50
  exit 1
fi

echo ""
echo "all tests passed"
