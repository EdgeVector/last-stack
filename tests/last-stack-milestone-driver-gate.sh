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

# Decompose-only: admission readable → proceed
printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":1},"work_queue":[{"action":"decompose","slug":"ms-b","north_star":"ns-a"}]}' >"$tmp/decomp.json"
export GATE_GAP_JSON="$tmp/decomp.json"
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
Updated-At: 2026-09-16
Updated-By: test
Reason: fixture
REC
run_case decompose-paused 0 'admission-paused'

# Unreadable board → skip
export GATE_GAP_JSON="$tmp/missing.json"
run_case board-unreadable 0 'board-unreadable'

# Unreadable admission record → skip
export GATE_GAP_JSON="$tmp/decomp.json"
rm -rf "$tmp/adm/get"
mkdir -p "$tmp/adm/get"
run_case admission-unreadable 0 'admission-unreadable'

echo "ok last-stack-milestone-driver-gate"
