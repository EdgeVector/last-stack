#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-red-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-canary-red-heal-routine"
bash -n "$ROOT/lib/canary-red/loom-canary-collect.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-heal.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-report.sh"

[ -f "$ROOT/routines/lastdb-canary-red-heal.md" ] || fail "canary-red-heal prompt missing"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing loom wrapper"
grep -q 'Close-out (always the LAST step)' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing close-out section"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch prompt missing canary-red hook"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood prompt missing canary-red hook"
grep -q 'NEVER skip the probe latency bar' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing probe-bar rule"

[ -f "$ROOT/lib/canary-red/canary-red-heal.json" ] || fail "lib graph missing"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$ROOT/lib/canary-red/canary-red-heal.json" \
  || fail "lib graph is not JSON"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-red.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- the gate lists from the same system that orchestrates the lane ---
LANE="$ROOT/bin/last-stack-canary-loom"
LISTER="$ROOT/bin/last-stack-loom-exec-latest"
[ -x "$LISTER" ] || fail "loom execution lister missing"

# What starts a lane execution, read from what executes, not from a comment.
lane_orch="$(grep -oE '^[^#]*[^a-zA-Z_-]?([a-z][a-z-]*) run lastdb-canary-release' "$LANE" \
  | sed -E 's/.*[^a-zA-Z_-]([a-z][a-z-]*) run lastdb-canary-release.*/\1/' | sort -u)"
[ "$lane_orch" = "loom" ] || fail "lane orchestrator is '$lane_orch', expected loom"

# What the gate lists from: the lister resolves loom's own schema over loom's
# socket. A retired `sm` read is the defect this card closes.
grep -q 'last-stack-loom-exec-latest' "$BIN" || fail "gate does not use the loom lister"
grep -q 'LoomExecution' "$LISTER" || fail "lister does not read loom's LoomExecution schema"
grep -q 'LOOM_SCHEMA_MAP' "$LISTER" || fail "lister does not read loom's schema map"
gate_orch="loom"
[ "$gate_orch" = "$lane_orch" ] \
  || fail "gate lists from '$gate_orch' but the lane runs on '$lane_orch'"

if grep -vE '^[[:space:]]*#' "$BIN" | grep -nE '(^|[^a-zA-Z_-])sm (list|get|start|show)' \
    >"$tmp/sm-hits.txt"; then
  fail "gate still reads the retired state machine: $(cat "$tmp/sm-hits.txt")"
fi

now_iso() { python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }

# --- a loom execution that failed inside the window is picked by its lx id ---
cat >"$tmp/loom-list.json" <<JSON
[
  {
    "id": "lx-20200101T000000.000-1-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "2020-01-01T00:00:00.000Z"
  },
  {
    "id": "lx-20260830T030901.571-75984-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 1)"
  }
]
JSON

export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp.json"
export CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json"

out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'lx-20260830T030901.571-75984-1' \
  || fail "dry-run json missing newest loom fail: $out"
printf '%s\n' "$out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("idle") is False, d
assert d.get("exec_id")=="lx-20260830T030901.571-75984-1", d'

# --- a running lane stays idle ---
cat >"$tmp/loom-idle.json" <<JSON
[{"id":"lx-20260830T031951.253-85350-1","definition_name":"lastdb-canary-release","status":"running","state":"SOAK_WAIT","updated_at":"$(now_iso 1)"}]
JSON
idle_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/loom-idle.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$idle_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="lane_busy", d'

# --- an empty listing is an ERROR, never a quiet lane ---
printf '%s\n' '[]' >"$tmp/empty.json"
set +e
empty_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/empty.json" "$BIN" --dry-run --json --quiet)"
empty_rc=$?
set -e
[ "$empty_rc" -eq 3 ] || fail "empty listing must exit 3, got $empty_rc: $empty_out"
printf '%s\n' "$empty_out" | grep -q 'no_executions_in_window' \
  || fail "empty listing missing no_executions_in_window: $empty_out"
printf '%s\n' "$empty_out" | grep -q 'outcome=error' \
  || fail "empty listing must report outcome=error: $empty_out"

# --- a listing whose newest row predates the window is ERROR, not idle ---
cat >"$tmp/stale.json" <<'JSON'
[{"id":"lx-20200101T000000.000-1-1","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","updated_at":"2020-01-01T00:00:00.000Z"}]
JSON
set +e
stale_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/stale.json" "$BIN" --dry-run --json --quiet)"
stale_rc=$?
set -e
[ "$stale_rc" -eq 3 ] || fail "stale listing must exit 3, got $stale_rc: $stale_out"
printf '%s\n' "$stale_out" | grep -q 'listing_stale' \
  || fail "stale listing missing listing_stale: $stale_out"
printf '%s\n' "$stale_out" | grep -qv 'failed_too_old' \
  || fail "stale listing must not report the old failed_too_old idle reason: $stale_out"

# stand-in scripts (no live agent)
cat >"$tmp/get.json" <<'JSON'
{"id":"exec_test","status":"failed","state":"FAILED","inputJson":"{\"main_oid\":\"abc\"}","contextJson":"{\"source_git_oid\":\"abc\",\"version\":\"0.1\"}"}
JSON
stand="$(
  LOOM_INPUT='{"exec_id":"exec_test","max_attempts":3}' \
  CANARY_RED_SM_GET_FILE="$tmp/get.json" \
    "$ROOT/lib/canary-red/loom-canary-collect.sh"
)"
printf '%s\n' "$stand" | grep -q 'verdict":"red"' || fail "collect stand-in missing red: $stand"
printf '%s\n' "$stand" | grep -q PASS || fail "collect missing PASS"

LOOM_IDEMPOTENCY_KEY=test-key LOOM_INPUT='{"exec_id":"exec_test","attempt":0}' \
  "$ROOT/lib/canary-red/loom-canary-heal.sh" | grep -q 'stand-in' \
  || fail "heal stand-in missing"

LOOM_INPUT='{"heal_status":"stand-in","attempt":2,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh" | grep -q 'exhausted' \
  || fail "retry stand-in missing exhausted at attempt 3"

CANARY_RED_SKIP_BRAIN=1 LOOM_INPUT='{"exec_id":"exec_test","verdict":"exhausted","attempt":3,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-report.sh" | grep -q PASS \
  || fail "report stand-in missing PASS"

# --- no loom → exit 3 ---
set +e
HOME="$tmp" PATH="/usr/bin:/bin" LAST_STACK_CANARY_RED_STAMP="$tmp/stamp2.json" \
  CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json" \
  "$BIN" --json --quiet --no-heal >"$tmp/noloom.out" 2>"$tmp/noloom.err"
nrc=$?
set -e
[ "$nrc" -eq 3 ] || fail "expected exit 3 without loom, got $nrc $(cat "$tmp/noloom.err")"

# --- mock loom run ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    cat <<'VIEW'
lx-canary-1
status: succeeded
state: DONE
context.verdict: "green"
context.heal_status: "fixed"
context.attempt: 1
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp3.json"
export CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json"
export LOOM_CANARY_RED_KEY="canary-red-test-key"
set +e
mout="$("$BIN" --json --quiet --no-heal)"
mrc=$?
set -e
[ "$mrc" -eq 0 ] || fail "mock loom exit $mrc: $mout"
printf '%s\n' "$mout" | grep -q '"outcome":"ok"' || fail "json missing outcome=ok: $mout"
printf '%s\n' "$mout" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $mout"
printf '%s\n' "$mout" | grep -q 'verdict=green' || fail "missing verdict=green: $mout"

# --- COLLECT reads loom, never the retired sm ---
# The fixture case above bypasses the reader entirely, which is how a COLLECT
# that shelled out to `sm get` with an `lx-*` id shipped and failed every live
# red. This exercises the reader itself.
ctmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-collect.XXXXXX")"
trap 'rm -rf "$ctmp"' EXIT
mkdir -p "$ctmp/bin"

cat >"$ctmp/bin/last-stack-loom-exec-latest" <<'SH'
#!/usr/bin/env bash
# Stub: answer --exec <lx-id> --full with a loom-shaped row.
want=""
full=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exec) want="${2:-}"; shift 2 ;;
    --full) full=1; shift ;;
    *) shift ;;
  esac
done
[ "$full" -eq 1 ] || { echo "stub: --full not requested" >&2; exit 9; }
case "$want" in
  lx-collect-test-1)
    cat <<'JSON'
[{"id":"lx-collect-test-1","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","input_json":"{\"main_oid\":\"deadbeefcafe0001\",\"max_attempts\":3}","last_error":"graph reached a fail state","hot_context_patch_json":"{\"version\":\"0.23.3\"}","parent_execution_id":""}]
JSON
    ;;
  *) echo "[]" ;;
esac
SH
chmod 755 "$ctmp/bin/last-stack-loom-exec-latest"

# Any call to the retired orchestrator must fail the test loudly.
cat >"$ctmp/bin/sm" <<'SH'
#!/usr/bin/env bash
echo "RETIRED_SM_WAS_CALLED $*" >&2
exit 1
SH
chmod 755 "$ctmp/bin/sm"

set +e
cout="$(
  PATH="$ctmp/bin:/usr/bin:/bin" \
  LOOM_INPUT='{"exec_id":"lx-collect-test-1","max_attempts":3}' \
    "$ROOT/lib/canary-red/loom-canary-collect.sh" 2>"$ctmp/collect.err"
)"
crc=$?
set -e
[ "$crc" -eq 0 ] || fail "collect against loom exited $crc: $(cat "$ctmp/collect.err")"
grep -q RETIRED_SM_WAS_CALLED "$ctmp/collect.err" && fail "collect still shells out to sm"
printf '%s\n' "$cout" | grep -q '"verdict":"red"' || fail "collect missing red verdict: $cout"
printf '%s\n' "$cout" | grep -q 'deadbeefcafe0001' || fail "collect lost source oid: $cout"
printf '%s\n' "$cout" | grep -q PASS || fail "collect missing PASS: $cout"

# An id loom does not hold must fail loudly, not silently collect an empty row.
set +e
PATH="$ctmp/bin:/usr/bin:/bin" \
LOOM_INPUT='{"exec_id":"lx-not-a-real-exec","max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-collect.sh" >"$ctmp/miss.out" 2>"$ctmp/miss.err"
mrc2=$?
set -e
[ "$mrc2" -ne 0 ] || fail "collect must fail on an execution loom does not hold"
grep -q 'loom get failed' "$ctmp/miss.err" \
  || fail "missing-exec error must name the loom read: $(cat "$ctmp/miss.err")"

# The two shipped copies of the node must not drift.
cmp -s "$ROOT/lib/canary-red/loom-canary-collect.sh" \
       "$ROOT/lib/canary-loom/loom-canary-collect.sh" \
  || fail "lib/canary-red and lib/canary-loom copies of loom-canary-collect.sh differ"

echo "ok"
