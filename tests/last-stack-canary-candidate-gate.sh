#!/usr/bin/env bash
# The nightly candidate gate orders its steps and stops where it must:
#   - a RED smoke stops BEFORE the cutover and writes no rows
#   - a GREEN smoke → cutover → rows (publish-next gets the set and the proof)
#   - a candidate equal to the primary, or a held cutover, runs the APPS-ONLY
#     pass: same set + same smoke pinned to the PRIMARY's lastdbd, rows
#     published, and never a cutover
#   - the apps-only pass is a noop when `next` already proves every app at the
#     set's pin for the build the primary runs, and when the same pins were
#     already smoked for this primary build inside the cooldown
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
k="\${FAKE_SET_KANBAN_SHA:-def}"
printf '{"lastdb":{"build":"0.23.3-200-gbbbbbbbbb"},"apps":{"brain":{"sha":"abc"},"kanban":{"sha":"%s"}}}\n' "\$k" >"\$out"
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
prim_bin="$work/primary-lastdbd"
printf '#!/usr/bin/env bash\necho "lastdbd 0.23.3-100-gaaaaaaaaa"\n' >"$prim_bin"; chmod +x "$prim_bin"
# `lastdb app resolve <app> --channel next --json`: what the registry already
# proves. FAKE_PROVED is a jq-readable map of app -> sha; anything absent
# resolves to nothing, which the gate must treat as MOVED.
cat >"$fake/lastdb" <<EOF
#!/usr/bin/env bash
echo "resolve \$*" >>"$calls"
app=""
while [ \$# -gt 0 ]; do case "\$1" in app|resolve) shift;; --channel|--lastdb-version) shift 2;; --json) shift;; *) app="\$1"; shift;; esac; done
printf '%s' "\${FAKE_PROVED:-{\}}" | jq -c --arg a "\$app" '{sha: (.[\$a] // "")}'
EOF
cat >"$fake/identity" <<EOF
#!/usr/bin/env bash
echo "build=\${FAKE_PRIMARY:-0.23.3-100-gaaaaaaaaa} identity_source=test"
EOF
chmod +x "$fake"/*

run_gate() {
  : >"$calls"
  # The apps-only cooldown is real state on disk. Every case below is about the
  # DECISION, so clear it per run; the cooldown cases opt in with
  # KEEP_APPS_ONLY_STAMPS=1. Without this, one case's stamp silences the next
  # case's smoke and the assertion passes for the wrong reason.
  [ "${KEEP_APPS_ONLY_STAMPS:-0}" = 1 ] || rm -rf "$work/apps-only-stamps"
  env ROUTINES_RUN_DIR="$work/run" \
    LAST_STACK_CANARY_V2_BUILD_MAIN="$fake/build-main" \
    LAST_STACK_CANARY_V2_DOGFOOD="$fake/dogfood" \
    LAST_STACK_CANARY_V2_PIPELINE="$fake/pipeline" \
    LAST_STACK_CANARY_CANDIDATE_SET_BIN="$fake/candidate-set" \
    LAST_STACK_CANARY_SMOKE_RUN="$fake/smoke.sh" \
    LAST_STACK_CANARY_PUBLISH_NEXT_BIN="$fake/publish-next" \
    LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="$fake/identity" \
    LAST_STACK_CANARY_PRIMARY_LASTDBD="$prim_bin" \
    LAST_STACK_CANARY_APP_RESOLVE_BIN="$fake/lastdb" \
    LAST_STACK_CANARY_APPS_ONLY_STAMP_DIR="$work/apps-only-stamps" \
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
grep -q 'record-line-event --check candidate_smoke' "$calls" && fail "RED smoke wrote a line event (the ledger has no build subject; observer/host would misgrade it)"

# Primary already on the candidate AND `next` already proves both app pins:
# a noop, and the expensive smoke must not run.
proved_both='{"brain":"abc","kanban":"def"}'
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED="$proved_both")"
grep -q 'ROUTINE_RESULT outcome=noop' <<<"$out" || fail "same build + proved apps not noop: $out"
grep -q 'primary_already_on_candidate_apps_already_proved' <<<"$out" || fail "noop evidence: $out"
grep -q '^smoke' "$calls" && fail "nothing to prove still ran the smoke"
grep -q 'dogfood --cutover' "$calls" && fail "nothing to prove still cut over"

# Primary already on the candidate and ONE app has moved past its row: the
# apps-only pass proves the set against the PRIMARY's lastdbd and publishes
# rows. This is the whole point of the pass — an app merge must not wait for
# the node to move.
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "apps-only pass not ok: $out"
grep -q 'stage=apps-only' <<<"$out" || fail "apps-only stage missing: $out"
grep -q 'moved=kanban' <<<"$out" || fail "moved app not named: $out"
grep -q 'rows=pr:EdgeVector/homebrew-lastdb/7' <<<"$out" || fail "apps-only wrote no rows: $out"
grep -q "smoke lastdbd=$prim_bin set=$work/run/apps-only-set.json" "$calls" \
  || fail "apps-only smoke did not boot the PRIMARY lastdbd on the apps-only set: $(cat "$calls")"
grep -q "candidate-set --lastdbd $prim_bin" "$calls" || fail "apps-only set not pinned to the primary build"
grep -q 'dogfood --cutover' "$calls" && fail "apps-only pass cut the primary over (there is no new build to cut over to)"
grep -q "publish-next --candidate-set $work/run/apps-only-set.json --proof $work/run/apps-only-proof.json" "$calls" \
  || fail "apps-only publish-next args"

# An app the registry cannot resolve at all counts as moved: a silent skip here
# is how the lag stayed invisible.
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}')"
grep -q 'moved=brain,kanban' <<<"$out" || fail "unresolvable rows not treated as moved: $out"

# Cutover held: same apps-only pass, still no cutover.
out="$(run_gate env FAKE_HOLD=true FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "held cutover did not run apps-only: $out"
grep -q 'after=quiet_window_near_complete' <<<"$out" || fail "apps-only did not say why: $out"
grep -q 'dogfood --cutover' "$calls" && fail "held cutover was performed by the apps-only pass"

# A RED apps-only smoke writes no rows.
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}' FAKE_SMOKE=RED)"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" || fail "red apps-only smoke not error: $out"
grep -q 'stage=apps-only' <<<"$out" || fail "red apps-only stage: $out"
grep -q 'publish-next' "$calls" && fail "RED apps-only smoke still wrote rows"

# No primary binary to boot: stay a noop and say so, rather than proving a pair
# against a build nothing ran.
out="$(run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}' LAST_STACK_CANARY_PRIMARY_LASTDBD="$work/absent-lastdbd")"
grep -q 'ROUTINE_RESULT outcome=noop' <<<"$out" || fail "absent primary binary not noop: $out"
grep -q 'primary_lastdbd_absent' <<<"$out" || fail "absent primary binary evidence: $out"
grep -q '^smoke' "$calls" && fail "absent primary binary still ran the smoke"

# The cooldown. This routine is not daily in practice — it fired 7 times on
# 2026-09-24, four of them inside 22 minutes, and every one of those was a
# `resolve` noop that the apps-only pass now picks up. Without a cooldown one
# busy evening buys four consecutive ~18-minute smokes for the same app pins,
# because a published row is not visible to `lastdb app resolve` until the tap
# PR merges and the mirror syncs.
rm -rf "$work/apps-only-stamps"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "first apps-only pass not ok: $out"
[ -f "$work/apps-only-stamps/0.23.3-200-gbbbbbbbbb.json" ] || fail "no apps-only stamp written"
jq -e '.result == "green" and (.fingerprint | length) == 64' "$work/apps-only-stamps/0.23.3-200-gbbbbbbbbb.json" >/dev/null \
  || fail "apps-only stamp shape: $(cat "$work/apps-only-stamps/0.23.3-200-gbbbbbbbbb.json")"

# Same primary build, same pins, immediately again: no second smoke.
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=noop' <<<"$out" || fail "second pass inside the cooldown not a noop: $out"
grep -q 'apps_only_cooldown' <<<"$out" || fail "cooldown evidence missing: $out"
grep -q '^smoke' "$calls" && fail "cooldown still ran the smoke"

# A pin that MOVED is a different fingerprint and must smoke again, cooldown or
# not: the cooldown bounds repeats of the same work, never new work.
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}' FAKE_SET_KANBAN_SHA=zzz)"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "a moved pin was suppressed by the cooldown: $out"
grep -q '^smoke' "$calls" || fail "a moved pin did not smoke"

# A RED set is stamped too, or it is re-smoked every ten minutes.
rm -rf "$work/apps-only-stamps"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}' FAKE_SMOKE=RED)"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" || fail "red apps-only not error: $out"
jq -e '.result == "red"' "$work/apps-only-stamps/0.23.3-200-gbbbbbbbbb.json" >/dev/null \
  || fail "red apps-only smoke left no stamp"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}' FAKE_SMOKE=RED)"
grep -q 'last=red' <<<"$out" || fail "red stamp did not hold the cooldown: $out"
grep -q '^smoke' "$calls" && fail "red set was re-smoked inside the cooldown"

# A zero cooldown is the escape hatch an operator needs.
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{}' LAST_STACK_CANARY_APPS_ONLY_COOLDOWN_SECS=0)"
grep -q '^smoke' "$calls" || fail "cooldown=0 still suppressed the smoke"

# A different primary build has its own stamp: a node cutover must re-prove.
rm -rf "$work/apps-only-stamps"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "stamp setup pass: $out"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-201-gccccccccc FAKE_INCOMING=0.23.3-201-gccccccccc FAKE_PROVED='{"brain":"abc"}')"
grep -q '^smoke' "$calls" || fail "a new primary build reused another build's cooldown stamp"

echo "PASS last-stack-canary-candidate-gate"
