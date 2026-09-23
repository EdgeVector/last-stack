#!/usr/bin/env bash
# Offline contract for north-star-exemem-hands-off-prod-deploy.
# Uses a fixture tree and a redacted evidence file. Does not deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-exemem-hands-off-prod-deploy/run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/exemem-hands-off-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-exemem-hands-off: $*" >&2
  exit 1
}

bash -n "$HARNESS"

"$RUNNER" --list | grep -qx 'north-star-exemem-hands-off-prod-deploy' ||
  fail "--list omits north-star-exemem-hands-off-prod-deploy"

write_fixture() {
  local root="$1"
  mkdir -p "$root/.lastgit" "$root/cdk/lib"
  cat >"$root/.lastgit/deploy-pipeline.sh" <<'EOF'
if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  write_progress frozen "DEPLOY_FREEZE"
  record_terminal success "skip=freeze"
  exit 0
fi
# 3. Deploy PROD (us-east-1) + pin ~10% traffic on new live-alias versions
EOF
  cat >"$root/.lastgit/canary-ticker.sh" <<'EOF'
if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  exit 0
fi
if ! canary_alarms_ok "$REGION"; then
  canary_log "ticker: ALARM during soak — rolling back all"
fi
canary_log "ticker: PROMOTED oid=$OID to 100%"
EOF
  cat >"$root/cdk/lib/exemem-stack.ts" <<'EOF'
// CodeDeploy canary traffic shifting + auto-rollback
// No human action.
const alarmTopic = `Exemem-Alarms-${envName}`
OBS_SENTRY_DSN
CANARY_10PERCENT_5MINUTES
deploymentInAlarm
EOF
}

write_evidence() {
  local path="$1" sentry="$2"
  cat >"$path" <<EOF
{
  "schema": "exemem-hands-off-prod-proof.v1",
  "primary_lastdb_opened": false,
  "prod_mutated_by_harness": false,
  "human_confirm_gate_present": false,
  "hands_off_promotion_100": true,
  "deploy_freeze_skips_prod": true,
  "alarm_rollback_without_manual": true,
  "sentry_failure_visible": $sentry,
  "evidence_refs": ["reference/proof-exemem-prod-live-fire-window-20260903"]
}
EOF
}

expect_verdict() {
  local report="$1" want="$2"
  local got
  got="$(sed -n '1p' "$report")"
  [ "$got" = "$want" ] || fail "first line is $got, want $want ($report)"
}

FIXTURE="$WORK/infra"
write_fixture "$FIXTURE"
write_evidence "$WORK/good.json" true

MARKER="$WORK/gbrain-called"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gbrain" <<EOF
#!/bin/sh
echo called >"$MARKER"
exit 1
EOF
chmod +x "$WORK/bin/gbrain"

PATH="$WORK/bin:$PATH" \
EXEMEM_HANDS_OFF_INFRA_ROOT="$FIXTURE" \
EXEMEM_HANDS_OFF_PROOF_EVIDENCE_FILE="$WORK/good.json" \
NORTH_STAR_PROOF_DIR="$WORK/reports" \
  "$RUNNER" --offline north-star-exemem-hands-off-prod-deploy >"$WORK/good.out"
[ ! -e "$MARKER" ] || fail "the evidence-file path called gbrain"
expect_verdict "$WORK/reports/north-star-exemem-hands-off-prod-deploy.md" PASS-OFFLINE
grep -q 'The harness does not deploy.' "$WORK/reports/north-star-exemem-hands-off-prod-deploy.md"
grep -q 'The harness does not open a LastDB home.' "$WORK/reports/north-star-exemem-hands-off-prod-deploy.md"

"$EVALUATOR" --kind validation \
  --predicate "file $WORK/reports/north-star-exemem-hands-off-prod-deploy.md matches /^PASS/" \
  >"$WORK/evaluator.out"
grep -q '^satisfied:' "$WORK/evaluator.out" || fail "PASS-OFFLINE did not satisfy /^PASS/"

write_evidence "$WORK/no-sentry.json" false
if EXEMEM_HANDS_OFF_INFRA_ROOT="$FIXTURE" \
  EXEMEM_HANDS_OFF_PROOF_EVIDENCE_FILE="$WORK/no-sentry.json" \
  NORTH_STAR_PROOF_DIR="$WORK/no-sentry" \
  "$RUNNER" --offline north-star-exemem-hands-off-prod-deploy >"$WORK/no-sentry.out" 2>&1; then
  fail "evidence without Sentry visibility was accepted"
fi
expect_verdict "$WORK/no-sentry/north-star-exemem-hands-off-prod-deploy.md" FAIL
grep -q 'sentry_failure_visible must be true' "$WORK/no-sentry/north-star-exemem-hands-off-prod-deploy.md"

printf '%s\n' 'confirm_prod_sha' >>"$FIXTURE/.lastgit/deploy-pipeline.sh"
if EXEMEM_HANDS_OFF_INFRA_ROOT="$FIXTURE" \
  EXEMEM_HANDS_OFF_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  NORTH_STAR_PROOF_DIR="$WORK/human-gate" \
  "$RUNNER" --offline north-star-exemem-hands-off-prod-deploy >"$WORK/human-gate.out" 2>&1; then
  fail "a confirm_prod_sha gate was accepted"
fi
expect_verdict "$WORK/human-gate/north-star-exemem-hands-off-prod-deploy.md" FAIL

write_fixture "$FIXTURE"
mkdir -p "$WORK/brain"
cat >"$WORK/brain/ns.txt" <<'EOF'
PASS: prod canary promoted to 100% and full-flow smoke green.
EOF
cat >"$WORK/brain/proof.txt" <<'EOF'
## 1. Freeze proof - PASS
stage=frozen
DEPLOY_FREEZE=true
## 2. Broken-canary auto-rollback - PASS
errorInformation.code=ALARM_ACTIVE
No manual intervention.
**OBS_SENTRY_DSN** is EMPTY on every prod lambda.
No prod lambda can send a Sentry event.
EOF
if EXEMEM_HANDS_OFF_INFRA_ROOT="$FIXTURE" \
  EXEMEM_HANDS_OFF_PROOF_BRAIN_DIR="$WORK/brain" \
  NORTH_STAR_PROOF_DIR="$WORK/brain-fail" \
  "$RUNNER" --offline north-star-exemem-hands-off-prod-deploy >"$WORK/brain-fail.out" 2>&1; then
  fail "the empty Sentry DSN record was accepted"
fi
expect_verdict "$WORK/brain-fail/north-star-exemem-hands-off-prod-deploy.md" FAIL
grep -q 'prod Sentry DSN is empty' "$WORK/brain-fail/north-star-exemem-hands-off-prod-deploy.md"
grep -q 'hands_off_promotion_100 is true' "$WORK/brain-fail/north-star-exemem-hands-off-prod-deploy.md"
grep -q 'deploy_freeze_skips_prod is true' "$WORK/brain-fail/north-star-exemem-hands-off-prod-deploy.md"
grep -q 'alarm_rollback_without_manual is true' "$WORK/brain-fail/north-star-exemem-hands-off-prod-deploy.md"

printf '%s\n' 'SENTRY_FAILURE_VISIBLE: yes' >>"$WORK/brain/proof.txt"
# The empty-DSN sentences still force a fail. Remove them for the positive case.
cat >"$WORK/brain/proof.txt" <<'EOF'
## 1. Freeze proof - PASS
stage=frozen
DEPLOY_FREEZE=true
## 2. Broken-canary auto-rollback - PASS
errorInformation.code=ALARM_ACTIVE
No manual intervention.
SENTRY_FAILURE_VISIBLE: yes
EOF
EXEMEM_HANDS_OFF_INFRA_ROOT="$FIXTURE" \
EXEMEM_HANDS_OFF_PROOF_BRAIN_DIR="$WORK/brain" \
NORTH_STAR_PROOF_DIR="$WORK/brain-pass" \
  "$RUNNER" --offline north-star-exemem-hands-off-prod-deploy >"$WORK/brain-pass.out"
expect_verdict "$WORK/brain-pass/north-star-exemem-hands-off-prod-deploy.md" PASS-OFFLINE

echo "PASS last-stack-north-star-proof-exemem-hands-off"
