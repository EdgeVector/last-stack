#!/usr/bin/env bash
# deploy-watch gate: deploys a moved green tip once, holds a pending or red
# tip, skips disabled repos, holds a tip whose deploy failed, and records the
# receipt so the next tick reads current. Fake tip/status/deploy commands.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-deploy-watch-gate"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/deploy-watch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
A="$(printf 'a%.0s' {1..40})"; B="$(printf 'b%.0s' {1..40})"; C="$(printf 'c%.0s' {1..40})"

cat >"$tmp/repos.json" <<JSON
{"defaults":{"forge_root":"http://forge.test","owner":"T","ref":"refs/heads/main","state_root":"$tmp/state"},
 "repos":[{"repo":"site","enabled":true,"context":"deploy-prod","deploy_script":".lastgit/deploy-prod.sh"},
          {"repo":"infra","enabled":false,"context":"deploy-pipeline","deploy_script":".lastgit/deploy-pipeline.sh"}]}
JSON
cat >"$tmp/tip" <<'SH'
#!/usr/bin/env bash
cat "${TIP_FILE:?}"
SH
cat >"$tmp/status" <<'SH'
#!/usr/bin/env bash
cat "${STATUS_FILE:?}"
SH
cat >"$tmp/deploy" <<'SH'
#!/usr/bin/env bash
echo "deploy $*" >>"${DEPLOY_LOG:?}"
[ "${DEPLOY_RC:-0}" = 0 ] && echo "DEPLOY_RESULT ok" || { echo "DEPLOY_RESULT failed"; exit "${DEPLOY_RC}"; }
SH
chmod +x "$tmp"/{tip,status,deploy}
run() {
  env LAST_STACK_DEPLOY_CONFIG="$tmp/repos.json" LAST_STACK_DEPLOY_LOOM_BIN="$tmp/deploy" \
    LAST_STACK_DEPLOY_TIP_CMD="$tmp/tip" LAST_STACK_DEPLOY_STATUS_CMD="$tmp/status" \
    TIP_FILE="$tmp/tip.txt" STATUS_FILE="$tmp/status.txt" DEPLOY_LOG="$tmp/deploy.log" "$@" "$GATE"
}
: >"$tmp/deploy.log"

# green moved tip → deploys, records receipt; disabled repo named
echo "$A" >"$tmp/tip.txt"; echo success >"$tmp/status.txt"
out="$(run)"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "green: $out"
grep -q "site=deployed@${A:0:12}" <<<"$out" && grep -q "infra=disabled" <<<"$out" || fail "green detail: $out"
grep -q -- "--repo site --oid $A" "$tmp/deploy.log" || fail "deploy args: $(cat "$tmp/deploy.log")"
[ "$(cat "$tmp/state/site/last-deployed")" = "$A" ] || fail "receipt not recorded"

# same tip → current, no deploy
out="$(run)"
grep -q 'outcome=noop' <<<"$out" && grep -q "site=current@${A:0:12}" <<<"$out" || fail "current: $out"
[ "$(grep -c deploy "$tmp/deploy.log")" = 1 ] || fail "deployed again on a current tip"

# new tip, CI pending → hold; CI failure → hold; nothing deployed
echo "$B" >"$tmp/tip.txt"; echo pending >"$tmp/status.txt"
out="$(run)"; grep -q "site=ci_pending@${B:0:12}" <<<"$out" && grep -q 'outcome=noop' <<<"$out" || fail "pending: $out"
echo failure >"$tmp/status.txt"
out="$(run)"; grep -q "site=ci_failure@${B:0:12}" <<<"$out" || fail "red: $out"
[ "$(grep -c deploy "$tmp/deploy.log")" = 1 ] || fail "deployed a non-green tip"

# green but the deploy fails → error once, then held on the same tip
echo success >"$tmp/status.txt"
out="$(run env DEPLOY_RC=3)"
grep -q 'outcome=error' <<<"$out" && grep -q "site=deploy_failed@${B:0:12}" <<<"$out" || fail "deploy failure: $out"
[ "$(cat "$tmp/state/site/last-deployed")" = "$A" ] || fail "failed deploy moved the receipt"
out="$(run env DEPLOY_RC=3)"
grep -q 'outcome=noop' <<<"$out" && grep -q "site=held_after_failure@${B:0:12}" <<<"$out" || fail "hold: $out"
[ "$(grep -c deploy "$tmp/deploy.log")" = 2 ] || fail "retried a failed tip on a timer"

# next green tip after the failure → deploys, hold cleared
echo "$C" >"$tmp/tip.txt"
out="$(run)"
grep -q "site=deployed@${C:0:12}" <<<"$out" || fail "recovery on new tip: $out"
[ ! -e "$tmp/state/site/last-failed" ] || fail "last-failed not cleared"

# unreadable tip → error
: >"$tmp/tip.txt"
out="$(run)"; grep -q 'outcome=error' <<<"$out" && grep -q "site=tip_unreadable" <<<"$out" || fail "unreadable: $out"

echo "PASS last-stack-deploy-watch-gate"
