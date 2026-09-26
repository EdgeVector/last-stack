#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-milestone-driver-gate"
chmod +x "$GATE"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/milestone-driver-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/last-stack/bin" "$tmp/adm/get"
cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'milestone gap-report --json') cat "${GATE_GAP_JSON:?}" ;;
  'milestone show ms-b --json') cat "${GATE_MS_SHOW_JSON:-/dev/null}" ;;
  'milestone detail '*' --json') [ -f "${GATE_FIXTURE_DIR:?}/detail-$3.json" ] || exit 9; cat "$GATE_FIXTURE_DIR/detail-$3.json" ;;
  'show '*' --json') [ -f "${GATE_FIXTURE_DIR:?}/card-$2.json" ] || exit 9; cat "$GATE_FIXTURE_DIR/card-$2.json" ;;
  *) exit 9 ;;
esac
SH
cat >"$tmp/last-stack/bin/last-stack-brain-append-heartbeat" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/bin/kanban" "$tmp/last-stack/bin/last-stack-brain-append-heartbeat" "$GATE"

export LAST_STACK_ROOT="$tmp/last-stack"
export PATH="$tmp/bin:/usr/bin:/bin"
export LAST_STACK_MILESTONE_DRIVER_GATE_KANBAN="$tmp/bin/kanban"
export LAST_STACK_MILESTONE_DRIVER_GATE_ADMISSION="$ROOT/bin/last-stack-feature-portfolio-admission"
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
export LAST_STACK_MILESTONE_DRIVER_GATE_PASS_RECORD="$ROOT/bin/last-stack-portfolio-pass-record"
export LAST_STACK_PORTFOLIO_PASSES_FILE="$tmp/passes.jsonl"

run_case() {
  local name="$1"
  local expected_rc="$2"
  local expected_text="$3"
  set +e
  out="$("$GATE" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "$name: expected rc=$expected_rc, got rc=$rc" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q "$expected_text"; then
    echo "$name: missing $expected_text" >&2
    echo "$out" >&2
    exit 1
  fi
}

printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":0},"work_queue":[]}' >"$tmp/empty.json"
export GATE_GAP_JSON="$tmp/empty.json"
run_case empty-frontier 0 'empty-frontier'

printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":0},"work_queue":[{"action":"promote","slug":"pr-a"}]}' >"$tmp/promote.json"
export GATE_GAP_JSON="$tmp/promote.json"
run_case promote 10 'reason=promote=1'

printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":0},"work_queue":[{"action":"complete_proof","slug":"ms-a"}]}' >"$tmp/proof.json"
export GATE_GAP_JSON="$tmp/proof.json"
run_case complete-proof 10 'reason=complete_proof=1'

# Decompose-only: real gap-report entries carry only {action, promoteable,
# slug} -- no north_star/northStar field. The gate must look the real value
# up on the milestone record itself, not the work_queue entry
# (papercut-milestone-driver-gate-north-star-filter-dead-20260926).
printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":1},"work_queue":[{"action":"decompose","slug":"ms-b"}]}' >"$tmp/decomp.json"
export GATE_GAP_JSON="$tmp/decomp.json"
printf '%s\n' '{"slug":"ms-b","north_star":"ns-a"}' >"$tmp/ms-b.json"
export GATE_MS_SHOW_JSON="$tmp/ms-b.json"
export LAST_STACK_ADMISSION_FIXTURE="$tmp/adm"
cat >"$tmp/adm/get/preference-feature-delivery-portfolio-admission.txt" <<'REC'
Policy-Version: 1
Primary: ns-a
Secondary: none
Paused:
Updated-At: 2026-09-16
Updated-By: test
Reason: fixture
REC
run_case decompose-admitted 10 'decompose-admitted'

# Decompose-only: paused north star → skip
cat >"$tmp/adm/get/preference-feature-delivery-portfolio-admission.txt" <<'REC'
Policy-Version: 1
Primary: other-ns
Secondary: none
Paused:
Updated-At: 2026-09-17
Updated-By: test
Reason: fixture
REC
run_case decompose-paused 0 'admission-paused'

# The gate records the portfolio pass even when it skips: a paused
# decompose-only queue is the starved state auto-refill must see. One record
# per admission Updated-At inside the 3000 s interval.
[ -s "$tmp/passes.jsonl" ] || { echo "gate wrote no portfolio pass record" >&2; exit 1; }
tail -n 1 "$tmp/passes.jsonl" | jq -e '.primary == "other-ns" and .idle_by_north_star == {}' >/dev/null \
  || { echo "unexpected pass record: $(tail -n 1 "$tmp/passes.jsonl")" >&2; exit 1; }
before="$(wc -l <"$tmp/passes.jsonl" | tr -d ' ')"
run_case decompose-paused-again 0 'admission-paused'
[ "$(wc -l <"$tmp/passes.jsonl" | tr -d ' ')" = "$before" ] \
  || { echo "gate must not record twice inside the min interval" >&2; exit 1; }

# Unreadable board → skip
export GATE_GAP_JSON="$tmp/missing.json"
run_case board-unreadable 0 'board-unreadable'

# Unreadable admission record → skip
export GATE_GAP_JSON="$tmp/decomp.json"
rm -rf "$tmp/adm/get"
mkdir -p "$tmp/adm/get"
run_case admission-unreadable 0 'admission-unreadable'


# ---------------------------------------------------------------------------
# Repair work (papercut-milestone-driver-gate-blind-to-proof-pending-repair-20260926):
# a proof_pending milestone whose proof card last verdict is a stale FAIL, and
# decompose entries flagged repair/next-slice, are never an empty frontier and
# are never skipped by the admission check.
# ---------------------------------------------------------------------------
export GATE_FIXTURE_DIR="$tmp/fx"
mkdir -p "$GATE_FIXTURE_DIR"
old_at="2026-09-06T00:00:00.000Z"
fresh_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
proof_pending_case() {
  # $1 card column, $2 updated_at, $3 body (JSON string content)
  printf '{"milestone":{"slug":"ms-pp","state":"active","deps":[],"proof_card":"pc-pp"}}\n' >"$GATE_FIXTURE_DIR/detail-ms-pp.json"
  printf '{"slug":"pc-pp","column":"%s","kind":"validation","updated_at":"%s","body":"%s"}\n' "$1" "$2" "$3" >"$GATE_FIXTURE_DIR/card-pc-pp.json"
}
printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":0,"proof_pending":1},"work_queue":[],"milestones":[{"slug":"ms-pp","status":"proof_pending","action":"await_proof"},{"slug":"ms-done","status":"complete","action":"skip"}]}' >"$tmp/pp-empty.json"
export GATE_GAP_JSON="$tmp/pp-empty.json"

proof_pending_case backlog "$old_at" 'PROOF[failed-offline-ns-proof]: last-stack-north-star-proof --offline FAIL sentry_failure_visible'
run_case proof-pending-stale-fail 10 'reason=proof-pending-repair=1'
proof_pending_case done "$old_at" 'PROOF: failed offline north-star-x — report remains FAIL'
run_case proof-pending-stale-failed-word 10 'reason=proof-pending-repair=1'
proof_pending_case done "$old_at" 'PROOF[reopened-end-state-unmet]: clause 2'
run_case proof-pending-reopened-unmet 10 'reason=proof-pending-repair=1'
proof_pending_case done "$old_at" 'PROOF: FAIL\nPROOF: passed — PASS clone_oid=abc'
run_case proof-pending-pass-after-fail 0 'empty-frontier'
proof_pending_case done "$fresh_at" 'PROOF: FAIL'
run_case proof-pending-fresh-fail 0 'empty-frontier'
proof_pending_case doing "$old_at" 'PROOF: FAIL'
run_case proof-pending-rerun-in-doing 0 'empty-frontier'
proof_pending_case done "$old_at" 'no verdict line'
run_case proof-pending-no-verdict 0 'empty-frontier'
rm -f "$GATE_FIXTURE_DIR/card-pc-pp.json"
run_case proof-pending-card-unreadable 0 'empty-frontier'

# Admission paused on a decompose-only queue: repair work still proceeds.
cat >"$tmp/adm/get/preference-feature-delivery-portfolio-admission.txt" <<'REC'
Policy-Version: 1
Primary: other-ns
Secondary: none
Paused:
Updated-At: 2026-09-18
Updated-By: test
Reason: fixture
REC
export GATE_MS_SHOW_JSON="$tmp/ms-b.json"
jq '.work_queue=[{"action":"decompose","slug":"ms-b"}] | .counts.idle_empty=1' "$tmp/pp-empty.json" >"$tmp/pp-paused.json"
export GATE_GAP_JSON="$tmp/pp-paused.json"
proof_pending_case backlog "$old_at" 'PROOF: FAIL'
run_case paused-plus-proof-pending-repair 10 'reason=proof-pending-repair=1'
proof_pending_case done "$old_at" 'PROOF: PASS'
run_case paused-no-repair 0 'admission-paused'
for flag in '"needs_next_slice":true' '"next_slice":true' '"stale_fail_proof":true,"from_status":"proof_pending"' '"work_class":"repair"'; do
  printf '{"counts":{"idle_promoteable":0,"idle_empty":1},"work_queue":[{"action":"decompose","slug":"ms-b",%s}]}\n' "$flag" >"$tmp/flag.json"
  export GATE_GAP_JSON="$tmp/flag.json"
  run_case "paused-repair-flag-$flag" 10 'reason=repair=1'
done
printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":1},"work_queue":[{"action":"decompose","slug":"ms-b"}],"milestones":[{"slug":"ms-b","status":"needs_next_slice","action":"decompose"}]}' >"$tmp/next-row.json"
export GATE_GAP_JSON="$tmp/next-row.json"
run_case paused-needs-next-slice-row 10 'reason=repair=1'

# Parity: the gate's jq verdict agrees with the snapshot's _proof_verdict.
sed -n "/^proof_card_filter='/,/^    else \"fresh-fail\" end'/p" "$GATE" \
  | sed "1s/^proof_card_filter='//; \$s/'\$//" >"$tmp/filter.jq"
[ -s "$tmp/filter.jq" ] || { echo "could not extract proof_card_filter from the gate" >&2; exit 1; }
cat >"$tmp/parity.py" <<'PYTEST'
import importlib.machinery
import importlib.util
import json
import subprocess
import sys
loader = importlib.machinery.SourceFileLoader('snapshot', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
bodies = [
    'PROOF: FAIL', 'RESULT: fail', 'PROOF: PASS', 'result: Passed.',
    'PROOF: failed offline north-star-x — report remains FAIL',
    'PROOF[failed-isolated-copy-contract]: x --offline FAIL',
    'PROOF[reopened-end-state-unmet]: clause 1',
    'PROOF[ Pass-live ]: ok', 'PROOF[offline-ns-proof]: rc=1 FAIL',
    'PROOF: fix-card filing failed', 'PROOF: FAIL\nPROOF: passed — ok',
    'PROOF: PASS\nPROOF[failed-x]: y', '  PROOF:   FAIL  ', 'PROOF: —failed—',
    'no verdict\nFAIL', '',
]
want_map = {'fail': 'stale-fail', 'pass': 'pass', None: 'none'}
for body in bodies:
    card = json.dumps({'column': 'done', 'updated_at': '2026-09-06T00:00:00Z', 'body': body})
    got = subprocess.run(['jq', '-r', '--arg', 'cadence', '3600', '-f', sys.argv[2]],
                         input=card, capture_output=True, text=True, check=True).stdout.strip()
    want = want_map[module._proof_verdict(body)]
    assert got == want, (body, want, got)
PYTEST
python3 "$tmp/parity.py" "$ROOT/bin/last-stack-milestone-driver-snapshot" "$tmp/filter.jq" \
  || { echo "gate proof verdict disagrees with the snapshot's _proof_verdict" >&2; exit 1; }
echo "ok repair work: proof_pending stale FAIL and repair/next-slice entries are never skipped"
echo "ok last-stack-milestone-driver-gate"
