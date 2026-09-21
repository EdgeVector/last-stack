#!/usr/bin/env bash
# deploy-main graph steps, driven the way Loom drives them (LOOM_INPUT + argv):
#   STAGE clones the exact OID (re-entrant), refuses a missing script;
#   DEPLOY runs the repo's script with the watcher's variables, writes a receipt,
#     emits the effect intent, fails on a non-zero script with the log tail;
#   CHECK answers 0 only for a landed receipt; a second DEPLOY reuses it;
#   VERIFY passes on exit 0, is skipped without a command, fails past the deadline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STEP="$ROOT/lib/deploy-loom/loom-deploy-step.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/deploy-loom-steps.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A repo with a deploy script that records its env and obeys DEPLOY_FAIL.
git init -q -b main "$tmp/src"
mkdir -p "$tmp/src/.lastgit"
cat >"$tmp/src/.lastgit/deploy-prod.sh" <<'SH'
#!/usr/bin/env bash
echo "deploy oid=$LASTGIT_CI_OID context=$LASTGIT_CI_CONTEXT repo=$LASTGIT_CI_REPO extra=${EXTRA_VAR:-none} pwd=$PWD"
[ "${DEPLOY_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 7; }
exit 0
SH
git -C "$tmp/src" add -A && git -C "$tmp/src" -c user.name=t -c user.email=t@example.com commit -q -m one
oid="$(git -C "$tmp/src" rev-parse HEAD)"
git clone -q --bare "$tmp/src" "$tmp/repo.git"
state="$tmp/state"

input() {
  jq -cn --arg repo demo --arg oid "$oid" --arg src "$tmp/repo.git" --arg script "${1:-.lastgit/deploy-prod.sh}" \
    --arg state "$state" --arg verify "${2:-}" \
    '{repo:$repo, oid:$oid, source_url:$src, deploy_script:$script, context:"deploy-prod", state_root:$state, verify_command:$verify, env:{EXTRA_VAR:"from-config"}}'
}

# STAGE
out="$(LOOM_INPUT="$(input)" "$STEP" STAGE)" || fail "STAGE failed: $out"
grep -q '^LOOM_CONTEXT_PATCH:.*"stage_dir"' <<<"$out" || fail "STAGE patch: $out"
[ "$(git -C "$state/demo/$oid/src" rev-parse HEAD)" = "$oid" ] || fail "stage is not at the OID"
LOOM_INPUT="$(input)" "$STEP" STAGE >/dev/null || fail "STAGE not re-entrant"
if LOOM_INPUT="$(input .lastgit/missing.sh)" "$STEP" STAGE >/dev/null 2>&1; then fail "STAGE accepted a missing script"; fi

# CHECK before deploy → 1
if LOOM_INPUT="$(input)" "$STEP" CHECK; then fail "CHECK passed before any deploy"; fi

# DEPLOY
out="$(LOOM_INPUT="$(input)" "$STEP" DEPLOY)" || fail "DEPLOY failed: $out"
grep -q '^LOOM_EFFECT_INTENT:{"kind":"deploy","target":"demo"}' <<<"$out" || fail "no effect intent: $out"
grep -q '"deployed":true' <<<"$out" || fail "DEPLOY patch: $out"
receipt="$state/demo/$oid/deploy-receipt.json"
[ "$(jq -r .rc "$receipt")" = 0 ] || fail "receipt rc"
grep -q "deploy oid=$oid context=deploy-prod repo=demo extra=from-config pwd=.*/state/demo/$oid/src" "$state/demo/$oid/deploy.log" \
  || fail "deploy script env/cwd: $(cat "$state/demo/$oid/deploy.log")"

# CHECK after deploy → 0; second DEPLOY reuses the receipt (no second run)
LOOM_INPUT="$(input)" "$STEP" CHECK || fail "CHECK failed after a landed deploy"
out="$(LOOM_INPUT="$(input)" "$STEP" DEPLOY)" || fail "second DEPLOY failed"
grep -q '"deploy_reused":true' <<<"$out" || fail "second DEPLOY did not reuse: $out"
[ "$(grep -c '^== deploy-main DEPLOY' "$state/demo/$oid/deploy.log")" = 1 ] || fail "deploy ran twice"

# VERIFY
out="$(LOOM_INPUT="$(input .lastgit/deploy-prod.sh 'test "$DEPLOY_OID" = "'"$oid"'"')" "$STEP" VERIFY)" || fail "VERIFY failed: $out"
grep -q '"verified":"ok"' <<<"$out" || fail "VERIFY patch: $out"
out="$(LOOM_INPUT="$(input)" "$STEP" VERIFY)" || fail "VERIFY without command failed"
grep -q '"verified":"skipped"' <<<"$out" || fail "VERIFY skip: $out"
if LOOM_DEPLOY_VERIFY_SECS=1 LOOM_INPUT="$(input .lastgit/deploy-prod.sh 'false')" "$STEP" VERIFY >/dev/null 2>"$tmp/v.err"; then
  fail "VERIFY passed a failing command"
fi
grep -q "did not pass before the deadline" "$tmp/v.err" || fail "VERIFY deadline message: $(cat "$tmp/v.err")"

# A failing deploy: non-zero, receipt rc=7, log tail on stderr, CHECK stays 1.
rm -rf "$state"
LOOM_INPUT="$(input)" "$STEP" STAGE >/dev/null
if DEPLOY_FAIL=1 LOOM_INPUT="$(input)" "$STEP" DEPLOY >/dev/null 2>"$tmp/d.err"; then fail "DEPLOY passed a failing script"; fi
grep -q "exited 7" "$tmp/d.err" && grep -q "boom" "$tmp/d.err" || fail "DEPLOY failure detail: $(cat "$tmp/d.err")"
[ "$(jq -r .rc "$state/demo/$oid/deploy-receipt.json")" = 7 ] || fail "failed receipt rc"
if LOOM_INPUT="$(input)" "$STEP" CHECK; then fail "CHECK passed after a failed deploy"; fi

echo "PASS last-stack-deploy-loom-steps"
