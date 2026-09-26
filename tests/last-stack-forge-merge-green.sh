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

# Fake situations preflight. The real one reads the live LastDB node, which a
# fixture must never touch. $FAKE_SITUATIONS_RC picks the answer:
#   0 -> OK (the default, so the gate stays LIVE in cases 1-6 and a regression
#        that refuses an ALLOWED merge fails those cases too)
#   3 -> BLOCKED, printing the slug<TAB>reason row `--field slug,reason` emits
#   2 -> a preflight that cannot answer
#        (papercut-situations-preflight-crashes-on-scope-routines-20260922)
cat >"$tmp/situations" <<'SH'
#!/usr/bin/env bash
rc="${FAKE_SITUATIONS_RC:-0}"
printf '%s rc=%s\n' "$*" "$rc" >>"$FAKE_FORGE_DIR/preflight.log"
case "$rc" in
  0) exit 0 ;;
  3) printf 'widget-hold-20260925\tblocked\n'; exit 3 ;;
  *) echo "situations: node did not respond within 30000ms" >&2; exit "$rc" ;;
esac
SH
chmod +x "$tmp/situations"
export LAST_STACK_SITUATIONS_BIN="$tmp/situations"
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

# 7) A Situation blocking merge-pr on this repo: refuse before ANY read or write.
#
#    The wrapper (last-stack#203) refuses the merge POST on its own, so the point
#    of this check is the SEQUENCE, not the merge. Without it, a blocked repo gets:
#      DELETE .../merge  -> cancels the owner's armed schedule (never guarded)
#      POST   .../merge  -> refused by the wrapper, verdict merge-failed
#      POST   .../merge  -> the recovery re-arm, also refused
#    i.e. the schedule is destroyed, nothing is merged, and the schedule cannot be
#    put back, reported as an opaque "merge-failed".
green_status; armed_at "2026-09-23T16:30:33Z"; reset
set +e
out="$(FAKE_SITUATIONS_RC=3 "$LEDGER" merge-green --repo "$R" --pr 7 --json --apply)"
rc=$?
set -e
v="$(printf '%s' "$out" | jq -r '.merge_green.verdict')"
[ "$v" = situations-blocked ] || fail "a blocked repo must report situations-blocked (got $v)"
[ "$rc" = 3 ] || fail "situations-blocked must exit 3 (got $rc)"
[ ! -s "$fx/writes.log" ] || fail "a blocked merge must write NOTHING, including the DELETE that cancels the owner's schedule"
grep -q '^DELETE' "$fx/writes.log" && fail "the schedule cancel must not run on a blocked repo"
printf '%s' "$out" | jq -e '.merge_green.policy == "blocked"' >/dev/null || fail "policy field must read blocked"
printf '%s' "$out" | jq -e '.merge_green.policy_detail | test("widget-hold-20260925")' >/dev/null \
  || fail "the refusal must carry the blocking Situation slug, not just a verdict"
# The text renderer must name the slug too: a verdict alone sends the reader back
# to preflight to find out which Situation refused.
set +e
txt="$(FAKE_SITUATIONS_RC=3 "$LEDGER" merge-green --repo "$R" --pr 7 --apply)"
set -e
case "$txt" in *widget-hold-20260925*) ;; *) fail "text output must name the Situation slug: $txt" ;; esac
grep -q 'merge-pr' "$fx/preflight.log" || fail "preflight was never called"
# Policy first, evidence second: with the PR fixture gone every forge read 404s,
# so a clean verdict proves nothing was read.
mv "$fx/repos_EdgeVector_widget_pulls_7.json" "$tmp/pr7.hidden"
set +e
v="$(FAKE_SITUATIONS_RC=3 "$LEDGER" merge-green --repo "$R" --pr 7 --json --apply | jq -r '.merge_green.verdict')"
set -e
mv "$tmp/pr7.hidden" "$fx/repos_EdgeVector_widget_pulls_7.json"
[ "$v" = situations-blocked ] || fail "policy must be checked before the PR is read (got $v)"

# 8) A preflight that cannot answer FAILS CLOSED here. The wrapper fails open on
#    this case so a broken install cannot stop every merge on the forge; this is a
#    scheduled repair verb with no operator watching, and its writes are exactly
#    the ones a hold exists to stop.
reset
set +e
out="$(FAKE_SITUATIONS_RC=2 "$LEDGER" merge-green --repo "$R" --pr 7 --json --apply)"
rc=$?
set -e
v="$(printf '%s' "$out" | jq -r '.merge_green.verdict')"
[ "$v" = situations-unreadable ] || fail "an unreadable preflight must fail closed (got $v)"
[ "$rc" = 3 ] || fail "situations-unreadable must exit 3 (got $rc)"
[ ! -s "$fx/writes.log" ] || fail "an unreadable policy must write nothing"

# 9) A host with no situations binary has no policy store to consult: proceed,
#    and say so in the report rather than passing silently.
green_status; armed_at "2026-09-23T16:30:33Z"; reset
mkdir -p "$tmp/empty-home"
out="$(env -u LAST_STACK_SITUATIONS_BIN PATH=/usr/bin:/bin HOME="$tmp/empty-home" \
  "$LEDGER" merge-green --repo "$R" --pr 7 --json --apply)"
v="$(printf '%s' "$out" | jq -r '.merge_green.verdict')"
[ "$v" = merged-now ] || fail "a host without situations must still merge (got $v)"
printf '%s' "$out" | jq -e '.merge_green.policy_detail | test("no situations binary")' >/dev/null \
  || fail "the fail-open path must name itself in the report"

# 10) A NAMED situations binary that does not exist is a broken configuration,
#     not a host without a policy store: fail closed, never fall through to 9.
green_status; armed_at "2026-09-23T16:30:33Z"; reset
set +e
v="$(LAST_STACK_SITUATIONS_BIN="$tmp/no-such-situations" \
  "$LEDGER" merge-green --repo "$R" --pr 7 --json --apply | jq -r '.merge_green.verdict')"
set -e
[ "$v" = situations-unreadable ] || fail "a missing NAMED preflight binary must fail closed (got $v)"
[ ! -s "$fx/writes.log" ] || fail "a missing NAMED preflight binary must write nothing"

echo "ok last-stack-forge-merge-green situations gate"
echo "ok last-stack-forge-merge-green"
