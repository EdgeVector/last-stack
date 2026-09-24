#!/usr/bin/env bash
# Fixture test for `last-stack-pipeline-forge-pr-ledger merge-green`.
#
# papercut-forgejo-auto-merge-armed-after-green-never-fires-20260923:
# Forgejo 15.0.3 evaluates a scheduled auto-merge only on a new commit-status
# event. schema-infra PR 7 was armed at 16:30Z, four minutes after its only
# required check went green, and never merged; a plain {"Do":"merge"} merged it
# at once. merge-green is the bounded fallback: it merges an ARMED green PR
# directly after a grace period, never merges an unarmed PR (unless --arm),
# and re-arms the schedule it cancelled when the direct merge fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LEDGER="$ROOT/bin/last-stack-pipeline-forge-pr-ledger"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fx="$tmp/forge"
mkdir -p "$fx"

# Fake forge: GET path -> fixture; --method writes are logged. A successful
# merge POST flips the PR fixture to merged; FAKE_MERGE_405=1 refuses it.
cat >"$tmp/forge-api" <<'SH'
#!/usr/bin/env bash
method=GET data=""
while [ "$#" -gt 1 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    *) break ;;
  esac
done
path="$1"
if [ "$method" != GET ]; then
  printf '%s %s %s\n' "$method" "$path" "$data" >>"$FAKE_FORGE_DIR/writes.log"
  case "$method:$data" in
    POST:*merge_when_checks_succeed*) exit 0 ;;
    POST:*)
      if [ "${FAKE_MERGE_405:-0}" = 1 ]; then echo "HTTP 405 POST $path" >&2; exit 1; fi
      touch "$FAKE_FORGE_DIR/merged.flag"; exit 0 ;;
    DELETE:*) exit 0 ;;
  esac
fi
key="$(printf '%s' "$path" | tr '/?&=' '____')"
if [ "$key" = "repos_EdgeVector_widget_pulls_7" ] && [ -f "$FAKE_FORGE_DIR/merged.flag" ]; then
  key="${key}_merged"
fi
f="$FAKE_FORGE_DIR/$key.json"
if [ -f "$f" ]; then cat "$f"; exit 0; fi
echo "HTTP 404 GET $path" >&2
exit 1
SH
chmod +x "$tmp/forge-api"
export FAKE_FORGE_DIR="$fx" LAST_STACK_FORGE_API="$tmp/forge-api"
export LAST_STACK_PR_LEDGER_NOW="2026-09-23T16:40:00Z"
put() { key="$(printf '%s' "$1" | tr '/?&=' '____')"; cat >"$fx/$key.json"; }

R=EdgeVector/widget
put "repos/$R/branch_protections" <<'J'
[{"rule_name":"main","enable_status_check":true,"status_check_contexts":["Forge CI / ci-required (pull_request)"]}]
J
put "repos/$R/pulls/7" <<'J'
{"number":7,"state":"open","merged":false,"mergeable":true,"draft":false,"head":{"sha":"h7"},"base":{"ref":"main"}}
J
put "repos/$R/pulls/7_merged" <<'J'
{"number":7,"state":"closed","merged":true,"merge_commit_sha":"c6b7e648"}
J
green_status() {
  put "repos/$R/commits/h7/status" <<'J'
{"state":"success","statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","updated_at":"2026-09-23T16:26:40Z"},
  {"context":"Forge CI / ci-required (pull_request)","status":"pending","updated_at":"2026-09-23T16:25:45Z"}]}
J
}
armed_at() {
  put "repos/$R/issues/7/timeline?limit=50&page=1" <<J
[{"type":"pull_push","created_at":"2026-09-23T16:25:39Z"},{"type":"pull_scheduled_merge","created_at":"$1"}]
J
}
not_armed() {
  put "repos/$R/issues/7/timeline?limit=50&page=1" <<'J'
[{"type":"pull_push","created_at":"2026-09-23T16:25:39Z"},{"type":"pull_scheduled_merge","created_at":"2026-09-23T16:30:33Z"},{"type":"pull_cancel_scheduled_merge","created_at":"2026-09-23T16:31:00Z"}]
J
}
reset() { rm -f "$fx/writes.log" "$fx/merged.flag"; : >"$fx/writes.log"; }
verdict() { "$LEDGER" merge-green --repo "$R" --pr 7 --json "$@" | jq -r '.merge_green.verdict'; }
fail() { echo "FAIL: $1" >&2; cat "$fx/writes.log" >&2; exit 1; }

# 1) Armed after green (the schema-infra PR 7 shape), idle past grace: merge directly.
green_status; armed_at "2026-09-23T16:30:33Z"; reset
v="$(verdict --apply)"
[ "$v" = merged-now ] || fail "armed green PR must merge directly (got $v)"
grep -q '^DELETE repos/EdgeVector/widget/pulls/7/merge' "$fx/writes.log" || fail "must cancel the stuck schedule first"
grep -q '^POST repos/EdgeVector/widget/pulls/7/merge {"Do": "merge", "delete_branch_after_merge": true}' "$fx/writes.log" || fail "must POST a plain merge"

# 2) Dry run reports would-merge and writes nothing.
reset
v="$(verdict)"
[ "$v" = would-merge ] || fail "dry run must report would-merge (got $v)"
[ ! -s "$fx/writes.log" ] || fail "dry run must not write"

# 3) Green but nobody armed it: never merge (proof may be in flight).
not_armed; reset
v="$(verdict --apply)"
[ "$v" = green-not-armed ] || fail "unarmed PR must not merge (got $v)"
[ ! -s "$fx/writes.log" ] || fail "unarmed PR must not write"
# ... unless the caller explicitly asks with --arm.
v="$(verdict --apply --arm)"
[ "$v" = merged-now ] || fail "--arm must merge a green PR (got $v)"

# 4) Armed inside the grace window: give native auto-merge its chance.
armed_at "2026-09-23T16:39:30Z"; reset
v="$(verdict --apply)"
[ "$v" = armed-green-wait ] || fail "inside grace must wait (got $v)"
[ ! -s "$fx/writes.log" ] || fail "inside grace must not write"

# 5) Pending checks: no merge.
put "repos/$R/commits/h7/status" <<'J'
{"state":"pending","statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"pending","updated_at":"2026-09-23T16:25:45Z"}]}
J
armed_at "2026-09-23T16:30:33Z"; reset
v="$(verdict --apply)"
[ "$v" = pending ] || fail "pending checks must not merge (got $v)"
[ ! -s "$fx/writes.log" ] || fail "pending checks must not write"

# 6) Merge refused with 405 (stuck status task): report it and re-arm.
green_status; reset
set +e
v="$(FAKE_MERGE_405=1 verdict --apply)"
set -e
[ "$v" = merge-405 ] || fail "405 must report merge-405 (got $v)"
tail -1 "$fx/writes.log" | grep -q 'merge_when_checks_succeed' || fail "a failed direct merge must re-arm the schedule it cancelled"

echo "ok last-stack-forge-merge-green"
