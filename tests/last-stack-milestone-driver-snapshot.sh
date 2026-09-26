#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="${MILESTONE_DRIVER_TEST_HELPER:-$ROOT/bin/last-stack-milestone-driver-snapshot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/run"
export FIXTURE_STATE="$TMP/state.json" FIXTURE_READS="$TMP/reads.log" FIXTURE_WRITES="$TMP/writes.log"
cat >"$FIXTURE_STATE" <<'JSON'
{"milestones":{"release":{"milestone":{"slug":"release","state":"active","deps":[],"proof_status":"pending","proof_card":"","body":"Acceptance requires executable synthetic proof","north_star":""},"proof_verdict":"pending"},"meter":{"milestone":{"slug":"meter","state":"planned","deps":[],"proof_status":"pending"},"proof_verdict":"pending"}},"card":{"slug":"card-a","column":"backlog","milestone":"release","block_status":"none","surfaces":["src/a.ts"]},"report":{"counts":{"idle_empty":1},"work_queue":[{"slug":"release","action":"decompose"},{"slug":"release","action":"complete_proof"},{"slug":"release","action":"promote","promoteable":["card-a"]}]}}
JSON
cat >"$TMP/bin/preflight" <<'EOF'
#!/usr/bin/env bash
exit "${PREFLIGHT_RC:-0}"
EOF
cat >"$TMP/bin/last-stack-feature-portfolio-admission" <<'EOF'
#!/usr/bin/env bash
echo '{"admitted_outcomes":[]}'
EOF
cat >"$TMP/bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_READS"
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json')
    if [ "${FAIL_PORTFOLIO:-0}" = 1 ]; then echo 'permission refused on BoardMilestones' >&2;exit 1;fi
    echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json') jq '.report' "$FIXTURE_STATE";;
  'milestone detail '* )
    if [ "${FAIL_DEP_READ:-}" = "$3" ]; then echo service_timeout >&2;exit 1;fi
    jq -e --arg slug "$3" '.milestones[$slug] // empty' "$FIXTURE_STATE";;
  'milestone show '* )
    jq -e --arg slug "$3" '.milestones[$slug].milestone // empty
      | {slug: .slug, north_star: (.north_star // "")}' "$FIXTURE_STATE";;
  'show card-a --json'|'show card-a --canonical --json') jq '.card' "$FIXTURE_STATE";;
  'move '*|'milestone add '*|'milestone state '*)
    printf '%s\n' "$*" >>"$FIXTURE_WRITES"; exit "${MUTATION_RC:-0}";;
  *) echo "unexpected fixture command: $*" >&2;exit 9;;
esac
EOF
cat >"$TMP/bin/last-stack-kanban-file-pr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_WRITES"
# The guard must preserve stdin for the existing decision/admission filer.
cat >"${FIXTURE_WRITES}.stdin"
[ -z "${MUTATION_SIGNAL_FILE:-}" ] || { touch "$MUTATION_SIGNAL_FILE"; sleep 2; }
exit "${MUTATION_RC:-0}"
EOF
chmod +x "$TMP/bin/"*
export KANBAN_BIN="$TMP/bin/kanban"
export MILESTONE_DRIVER_TARGET=release MILESTONE_DRIVER_SAFETY_CAP=1
run_dir="$TMP/run"; run_id=fixture; artifact="$run_dir/milestone-driver/gap-report.json"
capture() { "$HELPER" capture --run-dir "$run_dir" --run-id "$run_id" --preflight-bin "$TMP/bin/preflight" --kanban-bin "$KANBAN_BIN" --admission-bin "$TMP/bin/last-stack-feature-portfolio-admission"; }
guard() { "$HELPER" guard --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact" -- "$@"; }
change() { jq "$1" "$FIXTURE_STATE" >"$TMP/next.json"; mv "$TMP/next.json" "$FIXTURE_STATE"; }
reject() {
  local name="$1"; shift
  local before=0 after=0
  [ ! -e "$FIXTURE_WRITES" ] || before="$(wc -l <"$FIXTURE_WRITES")"
  if "$@" >"$TMP/reject.out" 2>"$TMP/reject.err"; then fail "$name accepted";fi
  [ ! -e "$FIXTURE_WRITES" ] || after="$(wc -l <"$FIXTURE_WRITES")"
  [ "$before" -eq "$after" ] || fail "$name reached mutation"
}
new_run() { run_id="$1";run_dir="$TMP/$1";artifact="$run_dir/milestone-driver/gap-report.json";capture >/dev/null; }
file_card() { guard "$TMP/bin/last-stack-kanban-file-pr" "$1" --milestone release --north-star ns --repo EdgeVector/fold --title title --column todo --surfaces src/a.ts; }

# Preflight rejects before any board read and clears old snapshot artifacts.
mkdir -p "$run_dir/milestone-driver"
echo '{}' >"$artifact"
if PREFLIGHT_RC=75 capture >"$TMP/preflight.out" 2>"$TMP/preflight.err"; then fail 'preflight accepted';fi
[ ! -e "$artifact" ] || fail 'old snapshot survived failed preflight'
[ ! -s "$FIXTURE_READS" ] || fail 'failed preflight read board'
grep -q 'no_board_commands=1' "$TMP/preflight.err" || fail 'preflight diagnostic missing'
capture >"$TMP/capture.json"
[ "$(wc -l <"$FIXTURE_READS")" -eq 6 ] || fail 'capture must retain five inventory reads plus one gap-report reconciliation read'
"$HELPER" consume --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact" >"$TMP/consumed.json"
jq -e '._milestone_driver_run.target=="release" and ._milestone_driver_run.safety_cap==1' "$TMP/consumed.json" >/dev/null || fail 'scope missing'
reject 'wrong run' "$HELPER" guard --run-dir "$run_dir" --run-id wrong --artifact "$artifact" -- "$KANBAN_BIN" move card-a todo
jq '._milestone_driver_run.created_epoch=0' "$artifact" >"$TMP/old.json";mv "$TMP/old.json" "$artifact"
reject 'old timestamp' "$HELPER" verify --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact"
capture >/dev/null

# Red-before compound case: permissive classifier + no harness must not waive proof.
reject 'missing harness waiver' guard "$KANBAN_BIN" milestone add release --proof-status not_required --json
grep -q 'proof-waiver-refused' "$TMP/reject.err" || fail 'waiver refusal did not explain proof policy'
reject 'premature passing' guard "$KANBAN_BIN" milestone add release --proof-status passing --json
reject 'missing harness complete' guard "$KANBAN_BIN" milestone state release complete --proof-status not_required --json
# Incomplete, missing, unreadable and transitive prerequisites are all unknown/held.
change '.milestones.release.milestone.deps=["meter"]'
reject 'incomplete dep file' file_card release-slice
reject 'incomplete dep promote' guard "$KANBAN_BIN" move card-a todo --json
change '.milestones.meter.milestone.state="complete" | .milestones.meter.milestone.proof_status="passing" | .milestones.meter.proof_verdict="pending"'
reject 'stale proof flag' file_card release-slice
change '.milestones.meter.proof_verdict="passing" | del(.milestones.meter.milestone.proof_status)'
reject 'missing dependency proof status' file_card release-slice
change '.milestones.meter.milestone.proof_status="pending"'
reject 'mismatched dependency proof status' file_card release-slice
change '.milestones.meter.milestone.proof_status="passing"'
FAIL_DEP_READ=meter reject 'read error' file_card release-slice
change '.milestones.release.milestone.deps=["missing"]'
reject 'missing dep' file_card release-slice
change '.milestones.release.milestone.deps=["meter"] | .milestones.meter.milestone.deps=["release"]'
reject 'cycle' file_card release-slice
change '.milestones.meter.milestone.deps=[]'
reject 'empty surfaces' guard "$TMP/bin/last-stack-kanban-file-pr" slice --milestone release --surfaces ' , '
reject 'scope mismatch' guard "$TMP/bin/last-stack-kanban-file-pr" slice --milestone meter --surfaces src/a.ts
reject 'unknown command' guard sh -c true
reject 'raw PR add' guard "$KANBAN_BIN" add slice --kind pr --column todo
reject 'force override' guard "$KANBAN_BIN" move card-a todo --force
change '.report.work_queue=[]';capture >/dev/null
reject 'action not in queue' file_card release-slice
change '.report.work_queue=[{"slug":"release","action":"decompose"},{"slug":"release","action":"promote","promoteable":["card-a"]},{"slug":"release","action":"complete_proof"}]';capture >/dev/null

# Duplicate graph edges reuse one exact dependency point read per action.
change '.milestones.release.milestone.deps=["meter","meter"]'
read_count="$(grep -c 'milestone detail meter --json' "$FIXTURE_READS")"
reject 'invalid proof attachment' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.milestones.release.milestone.board="default" | .card.board="default" | .card.kind="validation" | .card.body="Kind: validation\n## GOAL\nRun the existing synthetic proof.\n## END STATE\nThe existing proof passes.\nDONE-WHEN: fixture-proof exits zero"'
change '.card.kind="pr"'
reject 'proof attachment wrong kind' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.card.kind="validation" | .card.board="foreign"'
reject 'proof attachment wrong board' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.card.board="default" | .card.body="## GOAL\nGoal only.\nDONE-WHEN: fixture-proof exits zero"'
reject 'proof attachment missing end state' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.card.body="## END STATE\nEnd state only.\nDONE-WHEN: fixture-proof exits zero"'
reject 'proof attachment missing goal' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.card.body="## GOAL\n\n## END STATE\nEnd state only.\nDONE-WHEN: fixture-proof exits zero"'
reject 'proof attachment empty goal' guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
change '.card.body="## GOAL\nRun the existing synthetic proof.\n## END STATE\nThe existing proof passes.\nDONE-WHEN: fixture-proof exits zero"'
guard "$KANBAN_BIN" milestone add release --proof-card card-a --proof-status pending
[ "$(grep -c 'milestone detail meter --json' "$FIXTURE_READS")" -eq "$((read_count+1))" ] || fail 'duplicate dependency reads'
# Valid prerequisite evidence permits exactly one card; recapture cannot reset cap.
printf '%s\n' '## GOAL fixture body' | file_card release-slice
[ "$(cat "${FIXTURE_WRITES}.stdin")" = '## GOAL fixture body' ] || fail 'filer stdin lost'
capture >/dev/null
reject 'second action across recapture' guard "$KANBAN_BIN" move card-a todo --json
MILESTONE_DRIVER_SAFETY_CAP=8 reject 'cap changed' capture
MILESTONE_DRIVER_TARGET=meter reject 'target changed' capture
# New shell without environment still consumes frozen scope and budget.
env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" consume --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact" >"$TMP/frozen.json"
jq -e '._milestone_driver_run.safety_cap==1' "$TMP/frozen.json" >/dev/null || fail 'frozen cap lost'
reject 'omitted env frozen cap' env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact" -- "$KANBAN_BIN" move card-a todo
reject 'omitted env frozen target' env -u MILESTONE_DRIVER_TARGET -u MILESTONE_DRIVER_SAFETY_CAP "$HELPER" guard --run-dir "$run_dir" --run-id "$run_id" --artifact "$artifact" -- "$TMP/bin/last-stack-kanban-file-pr" wrong --milestone meter --surfaces src/a.ts
# Genuine pending-to-passing completion needs the linked canonical proof card.
change '.milestones.release.milestone.board="default" | .milestones.release.milestone.proof_card="card-a" | .card.board="default" | .card.kind="validation" | .card.column="done"'
reject 'pending proof without PASS' guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
change '.card.body += "\nPROOF: PASS" | .card.milestone="foreign"'
reject 'pending proof foreign milestone' guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
change '.card.milestone="release"'
guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
change '.card.column="backlog"'
reject 'pending proof nonterminal' guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
# A current proof permits completion without spending a card slot.
change '.milestones.release.milestone.proof_status="passing" | .milestones.release.proof_verdict="passing"'
guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
change '.milestones.release.milestone.proof_status="not_required" | .milestones.release.proof_verdict="not_required"'
guard "$KANBAN_BIN" milestone state release complete --proof-status not_required --json
change 'del(.milestones.release.milestone.proof_status)'
reject 'missing completion status' guard "$KANBAN_BIN" milestone state release complete --proof-status passing --json
change '.milestones.release.milestone.proof_status="passing" | .milestones.release.proof_verdict="passing"'

# Uncertain failures consume the reservation; never retry through a fresh snapshot.
new_run uncertain
if MUTATION_RC=9 file_card uncertain-slice; then fail 'command failure lost';fi
jq -e '.reserved_actions==1 and .actions[-1].exit_code==9' "$run_dir/milestone-driver/action-ledger.json" >/dev/null || fail 'command outcome missing'
capture >/dev/null
reject 'uncertain command retry' file_card uncertain-slice

# Nonblocking lock excludes concurrent guard/capture without stale-lock cleanup.
new_run concurrent
export MUTATION_SIGNAL_FILE="$TMP/command-started"
file_card concurrent-slice </dev/null >"$TMP/concurrent.out" 2>"$TMP/concurrent.err" & worker=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$MUTATION_SIGNAL_FILE" ] && break;sleep .1;done
[ -e "$MUTATION_SIGNAL_FILE" ] || fail 'concurrent fixture did not start'
reject 'locked second guard' file_card locked-slice
reject 'locked recapture' capture
grep -q 'run-action-in-progress' "$TMP/reject.err" || fail 'lock contention not explicit'
wait "$worker"
unset MUTATION_SIGNAL_FILE

# Point-read timeout is fixed and fails closed without a board mutation.
cat >"$TMP/timeout.py" <<'PYTEST'
import importlib.machinery
import importlib.util
import subprocess
import sys
from unittest.mock import patch
loader = importlib.machinery.SourceFileLoader('snapshot', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 30)) as run:
    try:
        module.point_read('fixture', ['milestone', 'detail', 'release'])
        raise AssertionError('timeout accepted')
    except module.Refusal as error:
        assert 'point-read-timeout' in error.reason
    assert run.call_args.kwargs['timeout'] == 30
PYTEST
python3 "$TMP/timeout.py" "$HELPER"

# Prior busy/error inventory diagnostics remain visible.
new_run portfolio-failure
if FAIL_PORTFOLIO=1 capture >"$TMP/pf.out" 2>"$TMP/pf.err";then fail 'portfolio failure accepted';fi
grep -q 'board-read-failed step=portfolio rc=1' "$TMP/pf.err" || fail 'portfolio diagnostic lost'
grep -q 'permission refused' "$TMP/pf.err" || fail 'stderr detail lost'
printf '%s\n' 'ok: milestone driver preserves proof, prerequisite gates, scope, cap, ledger, lock, freshness and preflight'
