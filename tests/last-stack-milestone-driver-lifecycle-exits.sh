#!/usr/bin/env bash
# Fixtures for the four milestone-driver dead-end lifecycle states:
#
# 1. gate north_star filter dead -- the gate must look a decompose entry's
#    North Star up on the milestone record, not the work_queue entry (which
#    never carries one in real gap-report output).
#    papercut-milestone-driver-gate-north-star-filter-dead-20260926
# 2. idle_empty with a stale FAIL terminal proof -- reconciliation must flag
#    it (`stale_fail_proof` + `proof_card`) instead of leaving it as a fresh
#    decompose candidate forever.
#    papercut-milestone-driver-never-reruns-stale-fail-proof-20260926
# 3. proof_ready (complete_proof) with no proof card at all -- reconciliation
#    must flag it (`missing_proof_card`) instead of leaving it uncounted.
#    papercut-milestones-with-done-work-and-no-proof-card-have-no-exit-20260926
# 4. decompose whose milestone body is a bare slug list -- reconciliation
#    must flag it (`needs_spec` + `sibling_milestones`) instead of silently
#    skipping it.
#    papercut-milestone-driver-rollup-body-milestones-block-decompose-20260926
# 5. proof_pending (await_proof) whose linked proof card's LAST verdict line
#    is a stale FAIL -- fkanban leaves it off the work_queue, so capture must
#    queue it as decompose + stale_fail_proof (+ from_status=proof_pending)
#    so the driver files the repair_proof card that carries the next slice.
#    The verdict parser must read the live validate-lane FAIL shapes.
# 6. needs_next_slice (fkanban: decompose + next_slice) with no proof card --
#    capture flags `missing_proof_card`, and the guard authorizes EITHER the
#    next Kind:pr slice OR the proof card (validation, cost 0). A plain
#    decompose (idle_empty) entry and an unqueued slug never authorize a
#    validation filing.
# 7. A milestone whose stored proof_status is `failing` and whose linked
#    terminal proof card's LAST verdict is now PASS: capture queues it as
#    complete_proof + proof_pass_close (fkanban scored it decompose), and the
#    guard authorizes the fkanban-legal two-step close:
#    `state <slug> proving --proof-status pending`, then
#    `state <slug> complete --proof-status passing`. A last FAIL is refused.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-milestone-driver-gate"
HELPER="$ROOT/bin/last-stack-milestone-driver-snapshot"
chmod +x "$GATE" "$HELPER"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/milestone-driver-lifecycle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fix 1: gate scopes admission by the milestone's real north_star, not a
# field the work_queue entry never carries.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/gate/bin" "$TMP/gate/last-stack/bin" "$TMP/gate/adm/get"
cat >"$TMP/gate/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'milestone gap-report --json')
    echo '{"counts":{"idle_promoteable":0,"idle_empty":1},"work_queue":[{"action":"decompose","slug":"ms-b"}]}';;
  'milestone show ms-b --json') echo '{"slug":"ms-b","north_star":"ns-paused"}';;
  *) exit 9;;
esac
SH
cat >"$TMP/gate/last-stack/bin/last-stack-brain-append-heartbeat" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/gate/bin/kanban" "$TMP/gate/last-stack/bin/last-stack-brain-append-heartbeat"
mkdir -p "$TMP/gate/adm/get"
cat >"$TMP/gate/adm/get/preference-feature-delivery-portfolio-admission.txt" <<'REC'
Policy-Version: 1
Primary: ns-other
Secondary: none
Paused:
Updated-At: 2026-09-16
Updated-By: test
Reason: fixture
REC

# RED-BEFORE (documents the bug, verified by hand against the pre-fix gate:
# reverting to `.north_star // .northStar // empty` on the work_queue entry
# reads empty here -- real entries never carry that field -- so the gate
# calls admission with no --north-star at all. Per evaluate() in
# last-stack-feature-portfolio-admission, no --north-star yields
# verdict=report/admitted=true unconditionally, so a paused North Star's
# decompose-only queue wrongly proceeds instead of skipping.)
#
# GREEN-AFTER: the candidate gate looks north_star up on the milestone
# record and correctly reports admission-paused for ns-paused.
out="$(LAST_STACK_ROOT="$TMP/gate/last-stack" \
  PATH="$TMP/gate/bin:/usr/bin:/bin" \
  LAST_STACK_MILESTONE_DRIVER_GATE_KANBAN="$TMP/gate/bin/kanban" \
  LAST_STACK_MILESTONE_DRIVER_GATE_ADMISSION="$ROOT/bin/last-stack-feature-portfolio-admission" \
  LAST_STACK_ADMISSION_FIXTURE="$TMP/gate/adm" \
  LAST_STACK_HEARTBEATS_FILE="$TMP/gate/heartbeats.log" \
  "$GATE" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "gate fix1: expected skip (rc=0), got rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'admission-paused' \
  || fail "gate fix1: expected admission-paused, got: $out"

# Sanity: an admitted north_star still proceeds (the lookup isn't just
# always-refusing).
cat >"$TMP/gate/adm/get/preference-feature-delivery-portfolio-admission.txt" <<'REC'
Policy-Version: 1
Primary: ns-paused
Secondary: none
Paused:
Updated-At: 2026-09-16
Updated-By: test
Reason: fixture
REC
set +e
out2="$(LAST_STACK_ROOT="$TMP/gate/last-stack" \
  PATH="$TMP/gate/bin:/usr/bin:/bin" \
  LAST_STACK_MILESTONE_DRIVER_GATE_KANBAN="$TMP/gate/bin/kanban" \
  LAST_STACK_MILESTONE_DRIVER_GATE_ADMISSION="$ROOT/bin/last-stack-feature-portfolio-admission" \
  LAST_STACK_ADMISSION_FIXTURE="$TMP/gate/adm" \
  LAST_STACK_HEARTBEATS_FILE="$TMP/gate/heartbeats.log" \
  "$GATE" 2>&1)"
rc2=$?
set -e
[ "$rc2" -eq 10 ] || fail "gate fix1: expected proceed (rc=10) once admitted, got rc=$rc2: $out2"
printf '%s\n' "$out2" | grep -q 'decompose-admitted' \
  || fail "gate fix1: expected decompose-admitted, got: $out2"

echo "ok fix1: gate scopes admission by the milestone's real north_star"

# ---------------------------------------------------------------------------
# Shared snapshot-fixture harness for fixes 2-4 (reconcile_gap_report
# annotation, exercised end-to-end through `capture`).
# ---------------------------------------------------------------------------
mkdir -p "$TMP/snap/bin"
cat >"$TMP/snap/bin/preflight" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/snap/bin/admission" <<'EOF'
#!/usr/bin/env bash
echo '{"admitted_outcomes":[]}'
EOF
chmod +x "$TMP/snap/bin/preflight" "$TMP/snap/bin/admission"

capture_artifact() {
  local kanban_bin="$1" run_dir="$2" run_id="$3"
  local out
  out="$("$HELPER" capture --run-dir "$run_dir" --run-id "$run_id" \
    --preflight-bin "$TMP/snap/bin/preflight" --kanban-bin "$kanban_bin" \
    --admission-bin "$TMP/snap/bin/admission")"
  printf '%s\n' "$out" | jq -r '.artifact'
}

# ---------------------------------------------------------------------------
# Fix 2: idle_empty (decompose) with a stale FAIL terminal proof report.
# ---------------------------------------------------------------------------
S2="$TMP/s2"
mkdir -p "$S2/run"
cat >"$S2/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1},"work_queue":[{"slug":"ms-stale-fail","action":"decompose"}]}';;
  'milestone show ms-stale-fail --json') echo '{"slug":"ms-stale-fail","north_star":""}';;
  'milestone detail ms-stale-fail --json')
    echo '{"milestone":{"slug":"ms-stale-fail","state":"active","deps":[],"proof_status":"pending","proof_card":"proof-card-old","body":"## Outcome\nDo the thing.\n## Acceptance\nIt works."},"proof_verdict":"pending"}';;
  'show proof-card-old --json')
    echo '{"slug":"proof-card-old","column":"done","kind":"validation","body":"PROOF: FAIL","updated_at":"2026-09-06T00:00:00Z"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S2/kanban"
artifact2="$(capture_artifact "$S2/kanban" "$S2/run" s2)"
jq -e '.work_queue[0].stale_fail_proof == true' "$artifact2" >/dev/null \
  || fail 'fix2: stale FAIL proof entry was not flagged stale_fail_proof'
jq -e '.work_queue[0].proof_card == "proof-card-old"' "$artifact2" >/dev/null \
  || fail 'fix2: stale FAIL proof entry lost its proof_card reference'
jq -e '.work_queue[0].action == "decompose"' "$artifact2" >/dev/null \
  || fail 'fix2: action must stay decompose (authorize() matches on the original action string)'
jq -e '.counts.stale_fail_proof == 1' "$artifact2" >/dev/null \
  || fail 'fix2: counts.stale_fail_proof not incremented'

# RED case: a *fresh* FAIL (inside the cadence window) must not be flagged --
# only a stale one should escape idle_empty as repair work.
S2B="$TMP/s2b"
mkdir -p "$S2B/run"
sed "s/2026-09-06T00:00:00Z/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$S2/kanban" >"$S2B/kanban"
chmod +x "$S2B/kanban"
artifact2b="$(capture_artifact "$S2B/kanban" "$S2B/run" s2b)"
jq -e '(.work_queue[0].stale_fail_proof // false) == false' "$artifact2b" >/dev/null \
  || fail 'fix2: a fresh (non-stale) FAIL must not be flagged yet'

echo "ok fix2: idle_empty with a stale FAIL proof is flagged for repair instead of re-counted"

# ---------------------------------------------------------------------------
# Fix 3: proof_ready (complete_proof) implementation done, no proof card.
# ---------------------------------------------------------------------------
S3="$TMP/s3"
mkdir -p "$S3/run"
cat >"$S3/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":0},"work_queue":[{"slug":"ms-no-card","action":"complete_proof"}]}';;
  'milestone detail ms-no-card --json')
    echo '{"milestone":{"slug":"ms-no-card","state":"active","deps":[],"proof_status":"pending","proof_card":""},"proof_verdict":"pending"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S3/kanban"
artifact3="$(capture_artifact "$S3/kanban" "$S3/run" s3)"
jq -e '.work_queue[0].missing_proof_card == true' "$artifact3" >/dev/null \
  || fail 'fix3: proof_ready-with-no-card entry was not flagged missing_proof_card'
jq -e '.work_queue[0].action == "complete_proof"' "$artifact3" >/dev/null \
  || fail 'fix3: action must stay complete_proof'
jq -e '.counts.missing_proof_card == 1' "$artifact3" >/dev/null \
  || fail 'fix3: counts.missing_proof_card not incremented'

# RED case: a milestone that already has a proof card must not be flagged --
# only a genuinely absent card is the dead end.
S3B="$TMP/s3b"
mkdir -p "$S3B/run"
cat >"$S3B/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":0},"work_queue":[{"slug":"ms-has-card","action":"complete_proof"}]}';;
  'milestone detail ms-has-card --json')
    echo '{"milestone":{"slug":"ms-has-card","state":"active","deps":[],"proof_status":"pending","proof_card":"proof-card-live"},"proof_verdict":"pending"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S3B/kanban"
artifact3b="$(capture_artifact "$S3B/kanban" "$S3B/run" s3b)"
jq -e '(.work_queue[0].missing_proof_card // false) == false' "$artifact3b" >/dev/null \
  || fail 'fix3: a milestone with a live proof card must not be flagged missing_proof_card'

echo "ok fix3: proof_ready with no proof card at all is flagged instead of left uncounted"

# ---------------------------------------------------------------------------
# Fix 4: decompose whose milestone body is a bare slug list.
# ---------------------------------------------------------------------------
S4="$TMP/s4"
mkdir -p "$S4/run"
cat >"$S4/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1},"work_queue":[{"slug":"ms-rollup","action":"decompose"}]}';;
  'milestone show ms-rollup --json') echo '{"slug":"ms-rollup","north_star":""}';;
  'milestone detail ms-rollup --json')
    echo '{"milestone":{"slug":"ms-rollup","state":"active","deps":[],"proof_status":"pending","proof_card":"","body":"child-ms-a\nchild-ms-b\nchild-ms-c"},"proof_verdict":"pending"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S4/kanban"
artifact4="$(capture_artifact "$S4/kanban" "$S4/run" s4)"
jq -e '.work_queue[0].needs_spec == true' "$artifact4" >/dev/null \
  || fail 'fix4: bare-slug-list decompose entry was not flagged needs_spec'
jq -e '.work_queue[0].sibling_milestones == ["child-ms-a","child-ms-b","child-ms-c"]' "$artifact4" >/dev/null \
  || fail 'fix4: sibling_milestones list not captured from the bare slug body'
jq -e '.work_queue[0].action == "decompose"' "$artifact4" >/dev/null \
  || fail 'fix4: action must stay decompose'
jq -e '.counts.needs_spec == 1' "$artifact4" >/dev/null \
  || fail 'fix4: counts.needs_spec not incremented'

# RED case: a real Outcome/Acceptance spec body must not be flagged.
S4B="$TMP/s4b"
mkdir -p "$S4B/run"
cat >"$S4B/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1},"work_queue":[{"slug":"ms-spec","action":"decompose"}]}';;
  'milestone show ms-spec --json') echo '{"slug":"ms-spec","north_star":""}';;
  'milestone detail ms-spec --json')
    echo '{"milestone":{"slug":"ms-spec","state":"active","deps":[],"proof_status":"pending","proof_card":"","body":"## Outcome\nDo the thing.\n## Acceptance\nIt works."},"proof_verdict":"pending"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S4B/kanban"
artifact4b="$(capture_artifact "$S4B/kanban" "$S4B/run" s4b)"
jq -e '(.work_queue[0].needs_spec // false) == false' "$artifact4b" >/dev/null \
  || fail 'fix4: a milestone with a real Outcome/Acceptance spec must not be flagged needs_spec'

echo "ok fix4: decompose with a bare slug-list body is flagged for a spec instead of silently skipped"

# ---------------------------------------------------------------------------
# Fix 5a: proof verdict parser -- the live validate-lane FAIL shapes match,
# the LAST verdict line wins, and PASS never reads as FAIL.
# ---------------------------------------------------------------------------
cat >"$TMP/verdict.py" <<'PYTEST'
import importlib.machinery
import importlib.util
import sys
loader = importlib.machinery.SourceFileLoader('snapshot', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
cases = [
    ('PROOF: FAIL', 'fail'),
    ('RESULT: FAIL', 'fail'),
    ('PROOF: failed offline north-star-exemem-hands-off-prod-deploy — report remains FAIL sentry_failure_visible', 'fail'),
    ('PROOF[failed-isolated-copy-contract]: last-stack-north-star-proof --offline FAIL north-star-x', 'fail'),
    ('PROOF[reopened-end-state-unmet]: END STATE clause 2 still unmet on main', 'fail'),
    ('## GOAL\nx\nPROOF: FAIL\nPROOF: passed clean-clone validation — PASS clone_oid=abc', 'pass'),
    ('PROOF: PASS', 'pass'),
    ('PROOF: passed — DONE-WHEN list fully satisfied', 'pass'),
    ('PROOF: PASS\nPROOF[failed-offline-ns-proof]: offline harness rc=1', 'fail'),
    ('PROOF[failed-offline-ns-proof]: rc=1\nPROOF[offline-ns-proof]: rc=1 report first_line=FAIL', 'fail'),
    ('PROOF: passed — x\nPROOF: fix-card filing failed during validate', 'pass'),
    ('no verdict here\nFAIL', None),
]
for body, want in cases:
    got = module._proof_verdict(body)
    assert got == want, (body, want, got)
PYTEST
python3 "$TMP/verdict.py" "$HELPER" || fail 'fix5a: proof verdict parser disagrees with the live proof-card shapes'
echo "ok fix5a: proof verdict parser reads the live FAIL shapes and lets the last verdict line win"

# ---------------------------------------------------------------------------
# Fix 5b: proof_pending milestone with a stale failing proof card is queued
# as decompose + stale_fail_proof; the guard then authorizes the repair card.
# ---------------------------------------------------------------------------
S5="$TMP/s5"
mkdir -p "$S5/run"
cat >"$S5/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":0,"proof_pending":3},"work_queue":[],"milestones":[
      {"slug":"ms-pp-fail","north_star":"ns-a","status":"proof_pending","action":"await_proof","pr_done":1},
      {"slug":"ms-pp-pass-after-fail","north_star":"ns-a","status":"proof_pending","action":"await_proof","pr_done":1},
      {"slug":"ms-pp-running","north_star":"ns-a","status":"proof_pending","action":"await_proof","pr_done":1},
      {"slug":"ms-done","north_star":"ns-a","status":"complete","action":"skip","pr_done":2}]}';;
  'milestone show '*) echo "{\"slug\":\"$3\",\"north_star\":\"ns-a\"}";;
  'milestone detail ms-pp-fail --json')
    echo '{"milestone":{"slug":"ms-pp-fail","state":"active","deps":[],"proof_status":"failing","proof_card":"pc-fail","board":"default"},"proof_verdict":"failing"}';;
  'milestone detail ms-pp-pass-after-fail --json')
    echo '{"milestone":{"slug":"ms-pp-pass-after-fail","state":"active","deps":[],"proof_status":"pending","proof_card":"pc-pass","board":"default"},"proof_verdict":"pending"}';;
  'milestone detail ms-pp-running --json')
    echo '{"milestone":{"slug":"ms-pp-running","state":"active","deps":[],"proof_status":"pending","proof_card":"pc-running","board":"default"},"proof_verdict":"pending"}';;
  'show pc-fail --json')
    echo '{"slug":"pc-fail","column":"backlog","kind":"validation","updated_at":"FAIL_UPDATED_AT","body":"## GOAL\nprove\nPROOF[failed-isolated-copy-contract]: last-stack-north-star-proof --offline FAIL clause restore_from_empty_home"}';;
  'show pc-pass --json')
    echo '{"slug":"pc-pass","column":"done","kind":"validation","updated_at":"2026-09-06T00:00:00Z","body":"PROOF: failed offline north-star-x — report remains FAIL\nPROOF: passed — PASS clone_oid=abc"}';;
  'show pc-running --json')
    echo '{"slug":"pc-running","column":"doing","kind":"validation","updated_at":"2026-09-06T00:00:00Z","body":"PROOF[reopened-end-state-unmet]: clause 1"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
sed 's/FAIL_UPDATED_AT/2026-09-06T00:00:00Z/' "$S5/kanban" >"$S5/kanban.tmp" && mv "$S5/kanban.tmp" "$S5/kanban"
chmod +x "$S5/kanban"
artifact5="$(capture_artifact "$S5/kanban" "$S5/run" s5)"
jq -e '[.work_queue[] | select(.slug == "ms-pp-fail")] | length == 1' "$artifact5" >/dev/null \
  || fail 'fix5b: proof_pending with a stale failing proof card was not queued'
jq -e '.work_queue[] | select(.slug == "ms-pp-fail")
  | .action == "decompose" and .stale_fail_proof == true and .proof_card == "pc-fail" and .from_status == "proof_pending"' \
  "$artifact5" >/dev/null || fail 'fix5b: queued proof_pending entry has the wrong shape'
jq -e '[.work_queue[] | select(.slug == "ms-pp-pass-after-fail")] | length == 0' "$artifact5" >/dev/null \
  || fail 'fix5b: a PASS verdict after a FAIL must not queue repair work'
jq -e '[.work_queue[] | select(.slug == "ms-pp-running")] | length == 0' "$artifact5" >/dev/null \
  || fail 'fix5b: a proof card in doing is being re-run and must not queue repair work'
jq -e '[.work_queue[] | select(.slug == "ms-done")] | length == 0' "$artifact5" >/dev/null \
  || fail 'fix5b: only proof_pending milestones are scanned'
jq -e '.counts.stale_fail_proof == 1 and .counts.proof_pending_stale_fail == 1' "$artifact5" >/dev/null \
  || fail 'fix5b: counts for the queued proof_pending repair not incremented'

# The guard authorizes exactly the repair_proof Kind:pr filing for it.
cat >"$S5/last-stack-kanban-file-pr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/writes.log"
EOF
chmod +x "$S5/last-stack-kanban-file-pr"
env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$S5/run" --run-id s5 --artifact "$artifact5" --kanban-bin "$S5/kanban" -- \
  "$S5/last-stack-kanban-file-pr" ms-pp-fail-repair-1 --milestone ms-pp-fail --north-star ns-a \
  --repo EdgeVector/fold --title repair --column todo --surfaces src/a.ts --work-class repair </dev/null \
  || fail 'fix5b: guard refused the repair_proof filing for a queued proof_pending milestone'
grep -q 'ms-pp-fail-repair-1 --milestone ms-pp-fail' "$S5/writes.log" || fail 'fix5b: repair card not filed'
if env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$S5/run" --run-id s5 --artifact "$artifact5" --kanban-bin "$S5/kanban" -- \
  "$S5/last-stack-kanban-file-pr" ms-pp-pass-repair --milestone ms-pp-pass-after-fail --north-star ns-a \
  --repo EdgeVector/fold --title repair --column todo --surfaces src/a.ts --work-class repair </dev/null 2>"$S5/reject.err"; then
  fail 'fix5b: guard filed repair work for a milestone whose proof passed'
fi
grep -q 'action-not-in-current-queue slug=ms-pp-pass-after-fail action=decompose' "$S5/reject.err" \
  || fail 'fix5b: refusal for an unqueued milestone not explicit'

# RED case: a fresh FAIL (inside the cadence window) is not queued yet.
S5B="$TMP/s5b"
mkdir -p "$S5B/run"
sed "s/2026-09-06T00:00:00Z\",\"body\":\"## GOAL/$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"## GOAL/" "$S5/kanban" >"$S5B/kanban"
chmod +x "$S5B/kanban"
grep -q "$(date -u +%Y-%m-%d)T" "$S5B/kanban" || fail 'fix5b: fresh-FAIL fixture rewrite did not apply'
artifact5b="$(capture_artifact "$S5B/kanban" "$S5B/run" s5b)"
jq -e '(.work_queue | length) == 0' "$artifact5b" >/dev/null \
  || fail 'fix5b: a fresh (non-stale) proof_pending FAIL must not be queued yet'

echo "ok fix5b: proof_pending with a stale failing proof is queued as repair work the guard authorizes"

# ---------------------------------------------------------------------------
# Fix 6: needs_next_slice -> the guard authorizes the next slice or the proof.
# ---------------------------------------------------------------------------
S6="$TMP/s6"
mkdir -p "$S6/run"
cat >"$S6/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1,"needs_next_slice":1},"work_queue":[
      {"slug":"ms-next","action":"decompose","promoteable":[]},
      {"slug":"ms-plain","action":"decompose","promoteable":[]}],"milestones":[
      {"slug":"ms-next","status":"needs_next_slice","action":"decompose","next_slice":true,"state":"active","pr_live":0,"pr_done":2,"proof_passing":false},
      {"slug":"ms-plain","status":"idle_empty","action":"decompose","state":"active","pr_live":0,"pr_done":0,"proof_passing":false}]}';;
  'milestone show '*) echo "{\"slug\":\"$3\",\"north_star\":\"ns-a\"}";;
  'milestone detail ms-next --json')
    echo '{"milestone":{"slug":"ms-next","state":"active","deps":[],"proof_status":"pending","proof_card":"","board":"default","body":"## Outcome\nx\n## Acceptance\n- a\n- b"},"proof_verdict":"pending"}';;
  'milestone detail ms-plain --json')
    echo '{"milestone":{"slug":"ms-plain","state":"active","deps":[],"proof_status":"pending","proof_card":"","board":"default","body":"## Outcome\nx\n## Acceptance\n- a"},"proof_verdict":"pending"}';;
  'milestone detail ms-unqueued --json')
    echo '{"milestone":{"slug":"ms-unqueued","state":"active","deps":[],"proof_status":"pending","proof_card":"","board":"default"},"proof_verdict":"pending"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S6/kanban"
artifact6="$(capture_artifact "$S6/kanban" "$S6/run" s6)"
# fkanban PR 44 puts next_slice on the milestones row only; capture stamps it
# onto the work_queue entry the guard reads.
jq -e '.work_queue[] | select(.slug == "ms-next")
  | .action == "decompose" and .next_slice == true and .missing_proof_card == true' "$artifact6" >/dev/null \
  || fail 'fix6: next_slice entry with an empty proof_card was not flagged missing_proof_card'
jq -e '.work_queue[] | select(.slug == "ms-plain") | (.missing_proof_card // false) == false' "$artifact6" >/dev/null \
  || fail 'fix6: a plain decompose entry must not be flagged missing_proof_card'
jq -e '.counts.missing_proof_card == 1' "$artifact6" >/dev/null \
  || fail 'fix6: counts.missing_proof_card not incremented for the next_slice entry'

cat >"$S6/last-stack-kanban-file-pr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/writes.log"
EOF
chmod +x "$S6/last-stack-kanban-file-pr"
guard6() {
  env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$S6/run" --run-id s6 \
    --artifact "$artifact6" --kanban-bin "$S6/kanban" -- "$S6/last-stack-kanban-file-pr" "$@" </dev/null
}
# The next Kind:pr slice (decompose, cost 1).
guard6 ms-next-slice-2 --milestone ms-next --north-star ns-a --repo EdgeVector/fold \
  --title slice --column todo --surfaces src/a.ts \
  || fail 'fix6: guard refused the next Kind:pr slice for a next_slice entry'
# The proof card (validation, cost 0).
guard6 ms-next-proof --milestone ms-next --north-star ns-a --repo EdgeVector/fold \
  --title proof --kind validation --work-class proof \
  || fail 'fix6: guard refused the proof card for a decompose + next_slice entry'
grep -q 'ms-next-slice-2 --milestone ms-next' "$S6/writes.log" || fail 'fix6: slice not filed'
grep -q 'ms-next-proof --milestone ms-next' "$S6/writes.log" || fail 'fix6: proof card not filed'
jq -e '.reserved_actions == 1' "$S6/run/milestone-driver/action-ledger.json" >/dev/null \
  || fail 'fix6: the proof card must cost 0 against SAFETY_CAP (slice 1 + proof 0)'
jq -e '[.actions[] | select(.milestone == "ms-next") | .action] == ["decompose","file_proof"]' \
  "$S6/run/milestone-driver/action-ledger.json" >/dev/null || fail 'fix6: ledger actions wrong'
# A second proof card for the same milestone in one run is refused.
if guard6 ms-next-proof-2 --milestone ms-next --north-star ns-a --repo EdgeVector/fold \
  --title proof --kind validation --work-class proof 2>"$S6/dup.err"; then
  fail 'fix6: guard filed a second proof card for the same milestone in one run'
fi
grep -q 'proof-card-already-filed-this-run slug=ms-next' "$S6/dup.err" || fail 'fix6: duplicate refusal not explicit'
# A plain decompose (idle_empty) entry never authorizes a proof card.
if guard6 ms-plain-proof --milestone ms-plain --north-star ns-a --repo EdgeVector/fold \
  --title proof --kind validation --work-class proof 2>"$S6/plain.err"; then
  fail 'fix6: guard filed a proof card for a plain decompose entry'
fi
grep -q 'action-not-in-current-queue slug=ms-plain action=file_proof' "$S6/plain.err" \
  || fail 'fix6: plain decompose refusal not explicit'
# A slug that is not in the queue never authorizes a proof card.
if guard6 ms-unqueued-proof --milestone ms-unqueued --north-star ns-a --repo EdgeVector/fold \
  --title proof --kind validation --work-class proof 2>"$S6/unq.err"; then
  fail 'fix6: guard filed a proof card for an unqueued milestone'
fi
grep -q 'action-not-in-current-queue slug=ms-unqueued action=file_proof' "$S6/unq.err" \
  || fail 'fix6: unqueued refusal not explicit'
! grep -q 'ms-plain-proof\|ms-unqueued-proof\|ms-next-proof-2' "$S6/writes.log" \
  || fail 'fix6: a refused filing reached the file-pr helper'

echo "ok fix6: needs_next_slice authorizes the next slice or the proof card; plain decompose does not"

# ---------------------------------------------------------------------------
# Fix 7: failing proof re-proved PASS -> two-step close; last FAIL refused.
# ---------------------------------------------------------------------------
S7="$TMP/s7"
mkdir -p "$S7/run"
export S7_STATE="$S7/state.json" S7_WRITES="$S7/writes.log"
cat >"$S7_STATE" <<'JSON'
{"milestones":{
  "ms-fixed":{"milestone":{"slug":"ms-fixed","state":"active","deps":[],"proof_status":"failing","proof_card":"pc-fixed","board":"default"},"proof_verdict":"failing"},
  "ms-still":{"milestone":{"slug":"ms-still","state":"active","deps":[],"proof_status":"failing","proof_card":"pc-still","board":"default"},"proof_verdict":"failing"}},
 "cards":{
  "pc-fixed":{"slug":"pc-fixed","column":"done","kind":"validation","milestone":"ms-fixed","board":"default","updated_at":"2026-09-06T00:00:00Z","body":"## GOAL\nprove\nPROOF[failed-isolated-copy-contract]: clause FAIL\nPROOF: PASS"},
  "pc-still":{"slug":"pc-still","column":"done","kind":"validation","milestone":"ms-still","board":"default","updated_at":"2026-09-06T00:00:00Z","body":"## GOAL\nprove\nPROOF: PASS\nPROOF: FAIL"}},
 "report":{"counts":{"idle_empty":2},"work_queue":[
   {"slug":"ms-fixed","action":"decompose","promoteable":[]},
   {"slug":"ms-still","action":"decompose","promoteable":[]}],"milestones":[
   {"slug":"ms-fixed","status":"idle_empty","action":"decompose","state":"active","pr_live":0,"pr_done":2,"proof_passing":true},
   {"slug":"ms-still","status":"idle_empty","action":"decompose","state":"active","pr_live":0,"pr_done":2,"proof_passing":true}]}}
JSON
cat >"$S7/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json') jq '.report' "$S7_STATE";;
  'milestone show '*) echo "{\"slug\":\"$3\",\"north_star\":\"ns-a\"}";;
  'milestone detail '*) jq -e --arg s "$3" '.milestones[$s] // empty' "$S7_STATE";;
  'show '*' --canonical --json'|'show '*' --json') jq -e --arg s "$2" '.cards[$s] // empty' "$S7_STATE";;
  'milestone state '*) printf '%s\n' "$*" >>"$S7_WRITES";;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S7/kanban"
artifact7="$(capture_artifact "$S7/kanban" "$S7/run" s7)"
jq -e '[.work_queue[] | select(.slug == "ms-fixed")] == [{"slug":"ms-fixed","action":"complete_proof","promoteable":[],
  "proof_pass_close":true,"proof_card":"pc-fixed","from_proof_status":"failing","from_state":"active"}]' "$artifact7" >/dev/null \
  || fail 'fix7: failing milestone with a last-PASS proof was not queued as complete_proof + proof_pass_close'
jq -e '[.work_queue[] | select(.slug == "ms-still" and .action == "complete_proof")] | length == 0' "$artifact7" >/dev/null \
  || fail 'fix7: a last-FAIL proof must not be queued for a close'
jq -e '.counts.proof_pass_close == 1' "$artifact7" >/dev/null || fail 'fix7: counts.proof_pass_close not set'

guard7() {
  env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$S7/run" --run-id s7 \
    --artifact "$artifact7" --kanban-bin "$S7/kanban" -- "$S7/kanban" "$@" </dev/null
}
# Direct complete from failing: fkanban refuses it (a failing proof forces
# `active`, and active -> complete is legal only for not_required), so the
# guard names the proving step instead of burning a doomed call.
if guard7 milestone state ms-fixed complete --proof-status passing --json 2>"$S7/direct.err"; then
  fail 'fix7: guard allowed a direct complete from proof_status=failing'
fi
grep -q 'failing-proof-enter-proving-first slug=ms-fixed' "$S7/direct.err" || fail 'fix7: direct-complete refusal not explicit'
# Step 1 needs --proof-status pending exactly.
if guard7 milestone state ms-fixed proving --proof-status passing --json 2>"$S7/s1bad.err"; then
  fail 'fix7: proving step accepted --proof-status passing'
fi
grep -q 'proving-step-requires-proof-status-pending' "$S7/s1bad.err" || fail 'fix7: proving-status refusal not explicit'
# failing + last PASS -> step 1 permitted.
guard7 milestone state ms-fixed proving --proof-status pending --json \
  || fail 'fix7: guard refused the proving step for failing + last PASS'
grep -q 'milestone state ms-fixed proving --proof-status pending --json' "$S7_WRITES" || fail 'fix7: proving step not run'
# fkanban applies step 1: proving + pending. Step 2 is then permitted.
jq '.milestones["ms-fixed"].milestone.state="proving" | .milestones["ms-fixed"].milestone.proof_status="pending"
  | .milestones["ms-fixed"].proof_verdict="pending"' "$S7_STATE" >"$S7_STATE.tmp" && mv "$S7_STATE.tmp" "$S7_STATE"
guard7 milestone state ms-fixed complete --proof-status passing --json \
  || fail 'fix7: guard refused the complete step after the proving step'
grep -q 'milestone state ms-fixed complete --proof-status passing --json' "$S7_WRITES" || fail 'fix7: complete step not run'
jq -e '.reserved_actions == 0' "$S7/run/milestone-driver/action-ledger.json" >/dev/null \
  || fail 'fix7: the close steps must cost 0 against SAFETY_CAP'
# failing + last FAIL -> refused by the proof check itself (it runs before the
# queue match, so a queued entry would not change the verdict).
if guard7 milestone state ms-still proving --proof-status pending --json 2>"$S7/still.err"; then
  fail 'fix7: guard allowed the proving step for failing + last FAIL'
fi
grep -q 'proving-step-proof-not-passing slug=ms-still' "$S7/still.err" || fail 'fix7: last-FAIL refusal not explicit'
! grep -q 'ms-still' "$S7_WRITES" || fail 'fix7: a refused close reached the board'

echo "ok fix7: failing proof re-proved PASS closes by proving -> complete; a last FAIL is refused"

echo "ok last-stack-milestone-driver-lifecycle-exits"
