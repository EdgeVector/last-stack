#!/usr/bin/env bash
# The nightly candidate gate orders its steps and stops where it must:
#   - a RED smoke stops BEFORE the cutover and writes no rows
#   - a GREEN smoke → cutover → rows (publish-next gets the set and the proof)
#   - a candidate equal to the primary is a noop (no smoke, no cutover)
#   - a cutover-hold from the channel policy is a noop
# Every tool is a fake that records its calls; nothing real runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-canary-candidate-gate"
work="$(mktemp -d "${TMPDIR:-/tmp}/candidate-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

fake="$work/fake"
mkdir -p "$fake" "$work/run"
calls="$work/calls.log"
: >"$calls"
cand_bin="$work/lastdbd"
printf '#!/usr/bin/env bash\necho "lastdbd 0.23.3-200-gbbbbbbbbb"\n' >"$cand_bin"; chmod +x "$cand_bin"

cat >"$fake/build-main" <<EOF
#!/usr/bin/env bash
echo "build-main \$*" >>"$calls"
echo '{"status":"already_staged"}'
EOF
cat >"$fake/dogfood" <<EOF
#!/usr/bin/env bash
echo "dogfood \$*" >>"$calls"
if [ "\$1" = "--dry-run" ]; then
  printf '{"version":"%s","safe_upgrade_args":["--candidate","%s"]}\n' "\${FAKE_INCOMING:-0.23.3-200-gbbbbbbbbb}" "$cand_bin"
else
  echo '{"safe_upgrade":"cutover-ok"}'
fi
EOF
cat >"$fake/pipeline" <<EOF
#!/usr/bin/env bash
echo "pipeline \$*" >>"$calls"
case "\$*" in
  *channels*) printf '{"cutover":{"hold":%s}}\n' "\${FAKE_HOLD:-false}" ;;
  *) echo '{}' ;;
esac
EOF
cat >"$fake/candidate-set" <<EOF
#!/usr/bin/env bash
echo "candidate-set \$*" >>"$calls"
out=""
while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2"; shift 2;; *) shift;; esac; done
printf '{"lastdb":{"build":"0.23.3-200-gbbbbbbbbb"},"apps":{"brain":{"sha":"abc"},"kanban":{"sha":"def"}}}\n' >"\$out"
EOF
cat >"$fake/smoke.sh" <<EOF
#!/usr/bin/env bash
echo "smoke lastdbd=\$SMOKE_LASTDBD_BIN set=\$SMOKE_CANDIDATE_SET" >>"$calls"
if [ "\${FAKE_SMOKE:-GREEN}" = GREEN ]; then
  echo '{"verdict":"GREEN","pass":20,"lastdb_build":"0.23.3-200-gbbbbbbbbb","proved_at":"2026-09-20T00:00:00Z"}'
  exit 0
fi
echo '{"verdict":"RED","steps":"install-apps"}'
exit 1
EOF
cat >"$fake/publish-next" <<EOF
#!/usr/bin/env bash
echo "publish-next \$*" >>"$calls"
echo "REGISTRY_NEXT status=pr build=0.23.3-200-gbbbbbbbbb apps=2 proof_run=run pr=EdgeVector/homebrew-lastdb/7"
EOF
cat >"$fake/identity" <<EOF
#!/usr/bin/env bash
echo "build=\${FAKE_PRIMARY:-0.23.3-100-gaaaaaaaaa} identity_source=test"
EOF
chmod +x "$fake"/*

run_gate() {
  : >"$calls"
  env ROUTINES_RUN_DIR="$work/run" \
    LAST_STACK_CANARY_V2_BUILD_MAIN="$fake/build-main" \
    LAST_STACK_CANARY_V2_DOGFOOD="$fake/dogfood" \
    LAST_STACK_CANARY_V2_PIPELINE="$fake/pipeline" \
    LAST_STACK_CANARY_CANDIDATE_SET_BIN="$fake/candidate-set" \
    LAST_STACK_CANARY_SMOKE_RUN="$fake/smoke.sh" \
    LAST_STACK_CANARY_PUBLISH_NEXT_BIN="$fake/publish-next" \
    LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="$fake/identity" \
    "$@" "$GATE"
}

# GREEN path: build → set → smoke → cutover → rows, in that order.
out="$(run_gate)"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "green path not ok: $out"
grep -q 'smoke=GREEN' <<<"$out" || fail "smoke verdict missing: $out"
grep -q 'rows=pr:EdgeVector/homebrew-lastdb/7' <<<"$out" || fail "rows PR missing: $out"
order="$(grep -oE '^(build-main|candidate-set|smoke|dogfood --cutover|publish-next)' "$calls" | tr '\n' ' ')"
[ "$order" = "build-main candidate-set smoke dogfood --cutover publish-next " ] || fail "step order: $order"
grep -q "smoke lastdbd=$cand_bin set=$work/run/candidate-set.json" "$calls" || fail "smoke did not get the candidate lastdbd and set"
grep -q "publish-next --candidate-set $work/run/candidate-set.json --proof $work/run/smoke-proof.json" "$calls" || fail "publish-next args"

# RED smoke: no cutover, no rows, build-subject line event.
out="$(run_gate env FAKE_SMOKE=RED)"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" || fail "red smoke not error: $out"
grep -q 'evidence=smoke_red' <<<"$out" || fail "red smoke evidence: $out"
grep -q 'dogfood --cutover' "$calls" && fail "RED smoke still cut over"
grep -q 'publish-next' "$calls" && fail "RED smoke still wrote rows"
grep -q 'record-line-event --check candidate_smoke --subject build --result fail' "$calls" || fail "no build-subject line event on RED"

# Primary already on the candidate: noop before any smoke.
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb)"
grep -q 'ROUTINE_RESULT outcome=noop' <<<"$out" || fail "same build not noop: $out"
grep -q 'primary_already_on_candidate' <<<"$out" || fail "noop evidence: $out"
grep -q '^smoke' "$calls" && fail "noop still ran the smoke"

# Cutover hold: noop.
out="$(run_gate env FAKE_HOLD=true)"
grep -q 'quiet_window_near_complete' <<<"$out" || fail "hold not honored: $out"
grep -q '^smoke' "$calls" && fail "hold still ran the smoke"

echo "PASS last-stack-canary-candidate-gate"
