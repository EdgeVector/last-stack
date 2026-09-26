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

echo "ok last-stack-milestone-driver-lifecycle-exits"
