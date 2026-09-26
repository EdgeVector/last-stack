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
#   - a FAILED primary cutover stays outcome=error AND still publishes app rows,
#     from an apps-only set pinned to the build the primary actually runs after
#     the failure -- unless that build cannot be read, in which case nothing is
#     published
#   - step 0 (primary-rows, also `--primary-rows-only [--detach]`) proves rows
#     for the build the primary runs when `next` has none: a noop on one
#     resolve when they exist, set + smoke on the PRIMARY lastdbd + publish when
#     they do not, no rows on a RED smoke, and never a build or a cutover
#   - step 0 also proves rows when the build is unchanged but an app head moved
#     past the pin `next` holds for it: a noop on the cheap head read when
#     nothing moved, set + smoke on the PRIMARY lastdbd + publish when one did,
#     no rows and a brain papercut on RED, no retry of a RED set until a head
#     moves, and at most one smoke an hour
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
  : >"$work/cutover-attempted"
  if [ "\${FAKE_CUTOVER:-ok}" = fail ]; then
    echo '{"safe_upgrade":"cutover-failed"}'
    exit 1
  fi
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
[ "\${FAKE_SET_FAIL:-0}" != 1 ] || { echo "forge unreachable" >&2; exit 1; }
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
# FAKE_RESOLVE=norow is the real CLI's answer for a build with no row (exit 1 +
# "no next row"); FAKE_RESOLVE=error is a resolve that cannot answer at all.
case "\${FAKE_RESOLVE:-map}" in
  norow) echo "error: no next row for app 'x' was proved with lastdb y" >&2; exit 1 ;;
  error) echo "error: index unreachable" >&2; exit 1 ;;
esac
app=""
while [ \$# -gt 0 ]; do case "\$1" in app|resolve) shift;; --channel|--lastdb-version) shift 2;; --json) shift;; *) app="\$1"; shift;; esac; done
printf '%s' "\${FAKE_PROVED:-{\}}" | jq -c --arg a "\$app" '{sha: (.[\$a] // "")}'
EOF
cat >"$fake/brain" <<EOF
#!/usr/bin/env bash
echo "brain \$*" >>"$calls"
case "\$1" in
  get) [ -n "\${FAKE_BRAIN_EXISTS:-}" ] || exit 1
       printf 'title: x\nstatus:     %s\n' "\$FAKE_BRAIN_EXISTS" ;;
  append) cat >"$work/brain-append.md" ;;
  papercut) while [ \$# -gt 0 ]; do case "\$1" in --body-file) cp "\$2" "$work/brain-file.md"; shift 2;; *) shift;; esac; done ;;
esac
EOF
cat >"$fake/identity" <<EOF
#!/usr/bin/env bash
# A cutover restarts the primary. FAKE_IDENTITY_FAIL_AFTER_CUTOVER models the
# window where it cannot be identified: readable at step 2, unreadable after.
if [ "\${FAKE_IDENTITY_FAIL_AFTER_CUTOVER:-0}" = 1 ] && [ -f "$work/cutover-attempted" ]; then
  exit 1
fi
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
  rm -f "$work/cutover-attempted"
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
    LAST_STACK_CANARY_PRIMARY_ROWS="${PRIMARY_ROWS:-0}" \
    LAST_STACK_CANARY_PRIMARY_ROWS_PROBE_APP=brain \
    LAST_STACK_CANARY_PRIMARY_ROWS_LOCK="$work/primary-rows.lock" \
    LAST_STACK_CANARY_PRIMARY_ROWS_LOG_DIR="$work/primary-rows-logs" \
    LAST_STACK_CANARY_BRAIN_BIN="$fake/brain" \
    "$@" "$GATE" ${GATE_FLAGS:-}
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

# ── a FAILED primary cutover must stay outcome=error AND publish app rows ────
# Step 6 sits below the cutover, so a cutover_failed run used to discard a GREEN
# app set: 3 of the 13 runs before 2026-09-26, including the one that left brain
# 5 commits behind its registry pin.
# papercut-canary-gate-discards-a-green-app-set-when-the-primary-cutover-fails-20260926
out="$(run_gate env FAKE_CUTOVER=fail FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" \
  || fail "a failed cutover must stay outcome=error (routinesd escalates on it): $out"
grep -q 'evidence=cutover_failed' <<<"$out" || fail "cutover failure evidence lost: $out"
grep -q 'apps_only=ok' <<<"$out" || fail "failed cutover did not run the apps-only pass: $out"
grep -q 'rows=pr:EdgeVector/homebrew-lastdb/7' <<<"$out" \
  || fail "failed cutover discarded the app rows: $out"
grep -q 'apps_only_moved=kanban' <<<"$out" \
  || fail "the failed-cutover line does not name which app got a row: $out"
grep -q "publish-next --candidate-set $work/run/apps-only-set.json --proof $work/run/apps-only-proof.json" "$calls" \
  || fail "failed cutover published the CANDIDATE set (the primary never took that build): $(cat "$calls")"
grep -q "smoke lastdbd=$prim_bin set=$work/run/apps-only-set.json" "$calls" \
  || fail "the apps-only proof after a failed cutover must boot the PRIMARY lastdbd"
order="$(grep -oE '^(candidate-set|smoke|dogfood --cutover|publish-next)' "$calls" | tr '\n' ' ')"
[ "$order" = "candidate-set smoke dogfood --cutover candidate-set smoke publish-next " ] \
  || fail "failed-cutover step order: $order"

# Nothing to prove after a failed cutover: still error, and no second smoke.
out="$(run_gate env FAKE_CUTOVER=fail FAKE_PROVED='{"brain":"abc","kanban":"def"}')"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" || fail "failed cutover not error: $out"
grep -q 'apps_only=noop' <<<"$out" || fail "already-proved apps not a noop: $out"
grep -q 'apps_only_evidence=apps_already_proved' <<<"$out" || fail "noop reason not named: $out"
[ "$(grep -c '^smoke' "$calls")" = 1 ] \
  || fail "a failed cutover with nothing to prove still bought a second smoke: $(cat "$calls")"
grep -q 'publish-next' "$calls" && fail "nothing to prove still wrote rows"

# The primary cannot be identified after the cutover: publish NOTHING. A row is
# a proved pair, and the second half is the build the host actually runs.
out="$(run_gate env FAKE_CUTOVER=fail FAKE_IDENTITY_FAIL_AFTER_CUTOVER=1 FAKE_PROVED='{"brain":"abc"}')"
grep -q 'ROUTINE_RESULT outcome=error' <<<"$out" || fail "failed cutover not error: $out"
grep -q 'apps_only=unknown' <<<"$out" || fail "unreadable primary not reported: $out"
grep -q 'apps_only_evidence=primary_identity_absent_after_cutover' <<<"$out" || fail "unreadable primary reason: $out"
grep -q 'publish-next' "$calls" \
  && fail "published a row against a primary build that could not be read"
[ "$(grep -c '^smoke' "$calls")" = 1 ] || fail "unreadable primary still ran the apps-only smoke"

# The cooldown is shared with the resolve exits on purpose: a primary that fails
# its cutover fails it again next run, and that must not buy a smoke each time.
rm -rf "$work/apps-only-stamps"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_CUTOVER=fail FAKE_PROVED='{"brain":"abc"}')"
grep -q 'apps_only=ok' <<<"$out" || fail "first failed-cutover apps-only pass: $out"
out="$(KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_CUTOVER=fail FAKE_PROVED='{"brain":"abc"}')"
grep -q 'apps_only=noop' <<<"$out" || fail "repeat failed cutover ignored the cooldown: $out"
grep -q 'apps_only_evidence=apps_only_cooldown' <<<"$out" || fail "cooldown reason: $out"
[ "$(grep -c '^smoke' "$calls")" = 1 ] || fail "repeat failed cutover re-smoked inside the cooldown"
rm -rf "$work/apps-only-stamps"

# ── step 0: primary-rows ───────────────────────────────────────────────────
# Any path can move the primary (lastdb-safe-upgrade moved it to 2375 at 12:53Z
# on 2026-09-26), and a build with no `next` row freezes every host-track
# install. Step 0 proves the app set against the build the primary runs, with
# the primary's own lastdbd, and never builds or cuts over.
# papercut-host-track-refresh-held-hours-after-lastdb-cutover-no-registry-proof-trigger-20260926
# The cheap head read (`candidate-set --no-version-lookup`) is not a step.
only_steps() { grep -v -- '--no-version-lookup' "$calls" | grep -oE '^(build-main|candidate-set|smoke|dogfood --cutover|publish-next)' | tr '\n' ' ' || true; }

# Rows exist for the primary build and no app head moved: the probe, one head
# read and one resolve per app, and nothing else.
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$proved_both")" || rc=$?
[ "$rc" = 0 ] || fail "rows-present probe exited $rc: $out"
grep -q '^PRIMARY_ROWS result=noop .*evidence=rows_present heads=current' <<<"$out" || fail "rows-present not a noop: $out"
grep -q 'ROUTINE_RESULT' <<<"$out" && fail "--primary-rows-only printed a ROUTINE_RESULT (its callers own that line): $out"
[ "$(grep -c '^resolve' "$calls")" = 3 ] || fail "rows-present cost more than probe + one resolve per app: $(cat "$calls")"
[ "$(grep -c -- "^candidate-set --lastdbd $prim_bin --no-version-lookup" "$calls")" = 1 ] \
  || fail "rows-present did not read the heads once, cheaply, from the primary lastdbd: $(cat "$calls")"
[ -z "$(only_steps)" ] || fail "rows-present still ran steps: $(only_steps)"
grep -q -- '--lastdb-version 0.23.3-100-gaaaaaaaaa' "$calls" || fail "probe did not ask for the PRIMARY build: $(cat "$calls")"

# Rows missing (the real CLI's "no next row" error): set + smoke on the PRIMARY
# lastdbd + publish, and never a build or a cutover.
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow)" || rc=$?
[ "$rc" = 0 ] || fail "rows-missing pass exited $rc: $out"
grep -q '^PRIMARY_ROWS result=ok .*stage=primary-rows' <<<"$out" || fail "rows-missing not ok: $out"
grep -q 'rows=pr:EdgeVector/homebrew-lastdb/7' <<<"$out" || fail "rows-missing wrote no rows: $out"
[ "$(only_steps)" = "candidate-set smoke publish-next " ] || fail "rows-missing steps: $(only_steps)"
grep -q "candidate-set --lastdbd $prim_bin" "$calls" || fail "set not pinned to the primary lastdbd"
grep -q "smoke lastdbd=$prim_bin" "$calls" || fail "smoke did not boot the primary lastdbd: $(cat "$calls")"
[ ! -d "$work/primary-rows.lock" ] || fail "--primary-rows-only left its lock behind"

# RED smoke: no rows, exit 1, no cutover.
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow FAKE_SMOKE=RED)" || rc=$?
[ "$rc" = 1 ] || fail "RED primary-rows smoke exited $rc, want 1: $out"
grep -q '^PRIMARY_ROWS result=red .*evidence=smoke_red' <<<"$out" || fail "RED primary-rows evidence: $out"
grep -q 'publish-next' "$calls" && fail "RED primary-rows smoke still wrote rows"
grep -q 'dogfood --cutover' "$calls" && fail "primary-rows cut over"

# The running build and the binary on disk differ: prove nothing.
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb)" || rc=$?
grep -q 'evidence=primary_binary_mismatch' <<<"$out" || fail "binary mismatch not caught: $out"
grep -q '^smoke' "$calls" && fail "binary mismatch still ran the smoke"

# A resolve that cannot answer must not buy a smoke; it is reported (exit 1).
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=error)" || rc=$?
[ "$rc" = 1 ] || fail "probe failure exited $rc, want 1: $out"
grep -q '^PRIMARY_ROWS result=unknown .*evidence=probe_failed' <<<"$out" || fail "probe failure evidence: $out"
[ -z "$(only_steps)" ] || fail "probe failure still ran steps: $(only_steps)"

# The kill switch.
out="$(PRIMARY_ROWS=0 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow)"
grep -q '^PRIMARY_ROWS result=skipped .*evidence=disabled' <<<"$out" || fail "kill switch: $out"
[ -z "$(only_steps)" ] || fail "kill switch still ran steps"

# A live holder of the lock (another worker, or a full gate mid-cutover).
mkdir -p "$work/primary-rows.lock"; printf '%s\n' "$$" >"$work/primary-rows.lock/pid"
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow)"
grep -q "evidence=locked holder=$$" <<<"$out" || fail "live lock not honoured: $out"
out="$(PRIMARY_ROWS=1 GATE_FLAGS='--primary-rows-only --detach' run_gate env FAKE_RESOLVE=norow)"
grep -q "evidence=locked holder=$$" <<<"$out" || fail "live lock not honoured by --detach: $out"
[ -z "$(only_steps)" ] || fail "locked runs still ran steps"
# A dead holder is taken over.
printf '%s\n' 999999 >"$work/primary-rows.lock/pid"
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_RESOLVE=norow)"
grep -q '^PRIMARY_ROWS result=ok' <<<"$out" || fail "stale lock not taken over: $out"
rm -rf "$work/primary-rows.lock"

# --detach: return at once with the worker's pid and log; the worker proves the
# rows in its own session.
out="$(PRIMARY_ROWS=1 GATE_FLAGS='--primary-rows-only --detach' run_gate env FAKE_RESOLVE=norow)"
grep -q '^PRIMARY_ROWS result=spawned .*evidence=rows_missing' <<<"$out" || fail "--detach did not spawn: $out"
log="$(sed -n 's/.* log=\([^ ]*\).*/\1/p' <<<"$out")"
[ -n "$log" ] || fail "--detach named no log: $out"
for _ in $(seq 1 100); do
  grep -q '^PRIMARY_ROWS result=' "$log" 2>/dev/null && break
  sleep 0.2
done
grep -q '^PRIMARY_ROWS result=ok' "$log" || fail "detached worker did not publish: $(cat "$log" 2>/dev/null)"
grep -q "smoke lastdbd=$prim_bin" "$calls" || fail "detached worker did not boot the primary lastdbd"
grep -q 'dogfood --cutover' "$calls" && fail "detached worker cut over"
for _ in $(seq 1 50); do [ -d "$work/primary-rows.lock" ] || break; sleep 0.1; done
[ ! -d "$work/primary-rows.lock" ] || fail "detached worker left its lock behind"

# --detach alone is a usage error.
rc=0
GATE_FLAGS=--detach run_gate >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--detach without --primary-rows-only exited $rc, want 2"

# The FULL gate runs step 0 first, before the expensive build, then carries on
# exactly as before.
rm -rf "$work/apps-only-stamps"
out="$(PRIMARY_ROWS=1 run_gate env FAKE_RESOLVE=norow)"
grep -q 'ROUTINE_RESULT outcome=ok' <<<"$out" || fail "full gate with step 0 not ok: $out"
grep -q 'primary_rows=ok' <<<"$out" || fail "full gate result does not report step 0: $out"
[ "$(only_steps)" = "candidate-set smoke publish-next build-main candidate-set smoke dogfood --cutover publish-next " ] \
  || fail "full gate order with step 0: $(only_steps)"
first_smoke="$(grep -m1 '^smoke' "$calls")"
[ "$first_smoke" = "smoke lastdbd=$prim_bin set=$work/run/apps-only-set.json" ] \
  || fail "step 0 smoke did not boot the primary: $first_smoke"
[ ! -d "$work/primary-rows.lock" ] || fail "full gate left its lock behind"

# Rows present: the full gate pays one resolve and keeps today's order.
out="$(PRIMARY_ROWS=1 run_gate env FAKE_PROVED="$proved_both")"
grep -q 'primary_rows=noop' <<<"$out" || fail "full gate rows-present: $out"
[ "$(only_steps)" = "build-main candidate-set smoke dogfood --cutover publish-next " ] \
  || fail "full gate order with rows present: $(only_steps)"
rm -rf "$work/apps-only-stamps"

# ── step 0: an app head moved while the build stayed the same ──────────────
# Rows pin exact app commits. fkanban PR 45 merged at 18:0xZ on 2026-09-26
# while the primary stayed on 2375, whose row pinned kanban b654aecf, and no
# row followed until the daily pass. Step 0 compares each head with its pin.
moved_kanban='{"brain":"abc","kanban":"old"}'
red_slug=papercut-canary-primary-rows-smoke-red-0-23-3-100-gaaaaaaaaa

# One head moved: set + smoke on the PRIMARY lastdbd + publish; no build, no cutover.
rm -rf "$work/apps-only-stamps"
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban")" || rc=$?
[ "$rc" = 0 ] || fail "heads-moved pass exited $rc: $out"
grep -q '^PRIMARY_ROWS result=ok .*stage=primary-rows' <<<"$out" || fail "heads-moved not ok: $out"
grep -q 'moved=kanban' <<<"$out" || fail "heads-moved did not name the app: $out"
grep -q 'after=primary_rows_heads_moved' <<<"$out" || fail "heads-moved did not say why: $out"
grep -q 'rows=pr:EdgeVector/homebrew-lastdb/7' <<<"$out" || fail "heads-moved wrote no rows: $out"
[ "$(only_steps)" = "candidate-set smoke publish-next " ] || fail "heads-moved steps: $(only_steps)"
grep -q "smoke lastdbd=$prim_bin set=$work/run/apps-only-set.json" "$calls" || fail "heads-moved smoke did not boot the primary lastdbd"
grep -q "publish-next --candidate-set $work/run/apps-only-set.json --proof $work/run/apps-only-proof.json" "$calls" \
  || fail "heads-moved publish-next args"
grep -q '^brain' "$calls" && fail "a GREEN heads pass touched the brain"
[ ! -d "$work/primary-rows.lock" ] || fail "heads-moved pass left its lock behind"

# The same pins again at once: rows are published but not yet served. No smoke.
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" LAST_STACK_CANARY_HEADS_SMOKE_INTERVAL_SECS=0)"
grep -q '^PRIMARY_ROWS result=noop .*evidence=heads_rows_pending' <<<"$out" || fail "published pins re-proved: $out"
[ -z "$(only_steps)" ] || fail "published pins still ran steps: $(only_steps)"

# Rate limit: a DIFFERENT head moves inside the hour. No smoke.
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SET_KANBAN_SHA=zzz)"
grep -q '^PRIMARY_ROWS result=noop .*evidence=heads_rate_limited' <<<"$out" || fail "rate limit not honoured: $out"
[ -z "$(only_steps)" ] || fail "rate-limited run still ran steps: $(only_steps)"
# The hour is over (interval 0): the new head is proved.
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SET_KANBAN_SHA=zzz LAST_STACK_CANARY_HEADS_SMOKE_INTERVAL_SECS=0)"
grep -q '^PRIMARY_ROWS result=ok' <<<"$out" || fail "a new head after the hour was not proved: $out"
[ "$(only_steps)" = "candidate-set smoke publish-next " ] || fail "new head after the hour steps: $(only_steps)"

# The rate limit counts smokes from every caller (here the full gate's
# apps-only pass), not only step 0's own.
rm -rf "$work/apps-only-stamps"
KEEP_APPS_ONLY_STAMPS=1 run_gate env FAKE_PRIMARY=0.23.3-200-gbbbbbbbbb FAKE_PROVED='{"brain":"abc"}' >/dev/null
jq -e '.result == "started"' "$work/apps-only-stamps/last-smoke.json" >/dev/null || fail "the apps-only smoke did not stamp the rate limit"
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban")"
grep -q 'evidence=heads_rate_limited' <<<"$out" || fail "another caller's smoke did not count: $out"

# RED: no rows, exit 1, a brain papercut with the smoke output.
rm -rf "$work/apps-only-stamps" "$work/brain-file.md"
rc=0
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SMOKE=RED)" || rc=$?
[ "$rc" = 1 ] || fail "RED heads pass exited $rc, want 1: $out"
grep -q '^PRIMARY_ROWS result=red .*evidence=smoke_red' <<<"$out" || fail "RED heads evidence: $out"
grep -q 'moved=kanban' <<<"$out" || fail "RED did not name the moved app: $out"
grep -q 'publish-next' "$calls" && fail "RED heads pass wrote rows"
grep -q 'dogfood --cutover' "$calls" && fail "RED heads pass cut over"
grep -q "papercut=filed:$red_slug" <<<"$out" || fail "RED filed no papercut: $out"
grep -q "^brain papercut file $red_slug .*--component canary-candidate-gate" "$calls" || fail "papercut filing args: $(cat "$calls")"
grep -q 'install-apps' "$work/brain-file.md" || fail "papercut body lacks the smoke output: $(cat "$work/brain-file.md")"
grep -q 'moved apps: kanban' "$work/brain-file.md" || fail "papercut body lacks the moved app"

# The same RED set an hour later: not smoked again, no second papercut.
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SMOKE=RED LAST_STACK_CANARY_HEADS_SMOKE_INTERVAL_SECS=0 LAST_STACK_CANARY_APPS_ONLY_COOLDOWN_SECS=0)"
grep -q '^PRIMARY_ROWS result=noop .*evidence=heads_red_unchanged' <<<"$out" || fail "persistent RED re-smoked: $out"
[ -z "$(only_steps)" ] || fail "persistent RED still ran steps: $(only_steps)"
grep -q '^brain' "$calls" && fail "persistent RED touched the brain again"

# A head moves again: smoke again, and a RED appends to the open papercut.
rc=0
out="$(KEEP_APPS_ONLY_STAMPS=1 PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SMOKE=RED FAKE_SET_KANBAN_SHA=zzz FAKE_BRAIN_EXISTS=open LAST_STACK_CANARY_HEADS_SMOKE_INTERVAL_SECS=0)" || rc=$?
[ "$(only_steps)" = "candidate-set smoke " ] || fail "a moved head after RED did not re-smoke: $(only_steps)"
grep -q "papercut=appended:$red_slug" <<<"$out" || fail "second RED did not append to the open papercut: $out"
grep -q "^brain append $red_slug --type papercut" "$calls" || fail "append args: $(cat "$calls")"

# A head read that fails is reported and buys no smoke.
rc=0
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" FAKE_SET_FAIL=1)" || rc=$?
[ "$rc" = 1 ] || fail "unreadable heads exited $rc, want 1: $out"
grep -q '^PRIMARY_ROWS result=unknown .*evidence=heads_unreadable' <<<"$out" || fail "unreadable heads evidence: $out"
grep -q '^smoke' "$calls" && fail "unreadable heads still ran the smoke"

# The head check has its own kill switch; the rows-present probe stays.
out="$(PRIMARY_ROWS=1 GATE_FLAGS=--primary-rows-only run_gate env FAKE_PROVED="$moved_kanban" LAST_STACK_CANARY_PRIMARY_ROWS_HEADS=0)"
grep -q '^PRIMARY_ROWS result=noop .*evidence=rows_present heads=skipped' <<<"$out" || fail "heads kill switch: $out"
grep -q '^candidate-set' "$calls" && fail "heads kill switch still read the heads"

# --detach with a moved head: spawn, and the worker proves the set.
rm -rf "$work/apps-only-stamps"
out="$(PRIMARY_ROWS=1 GATE_FLAGS='--primary-rows-only --detach' run_gate env FAKE_PROVED="$moved_kanban")"
grep -q '^PRIMARY_ROWS result=spawned .*evidence=heads_moved moved=kanban' <<<"$out" || fail "--detach did not spawn on a moved head: $out"
log="$(sed -n 's/.* log=\([^ ]*\).*/\1/p' <<<"$out")"
for _ in $(seq 1 100); do
  grep -q '^PRIMARY_ROWS result=' "$log" 2>/dev/null && break
  sleep 0.2
done
grep -q '^PRIMARY_ROWS result=ok .*after=primary_rows_heads_moved' "$log" || fail "detached heads worker did not publish: $(cat "$log" 2>/dev/null)"
for _ in $(seq 1 50); do [ -d "$work/primary-rows.lock" ] || break; sleep 0.1; done
rm -rf "$work/apps-only-stamps"

echo "PASS last-stack-canary-candidate-gate"
