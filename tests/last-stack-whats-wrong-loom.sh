#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-whats-wrong-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-whats-wrong-routine"
bash -n "$ROOT/lib/lastdb-retry-schedule.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-list.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-closeout.sh"
if grep -q 'GATE_TIMEOUT_CAP_MS' "$BIN"; then
  fail "whats-wrong loom wrapper still names the retired gate cap"
fi

[ -f "$ROOT/routines/whats-wrong.md" ] || fail "whats-wrong prompt missing"
grep -q 'last-stack-whats-wrong-loom' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing loom hook"
grep -q 'Close-out (always the LAST step)' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing close-out section"
grep -q 'coverage.exceptions' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing snapshot field"

[ -f "$ROOT/lib/whats-wrong/whats-wrong.json" ] || fail "lib graph missing"
[ -f "$ROOT/lib/whats-wrong/whats-wrong-item.json" ] || fail "lib item graph missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/snap.json" <<'JSON'
{"coverage":{"exceptions":[
  {"id":"ship.why-stopped-loom","label":"why-loom","L":"x","F":" ","T":"x","why":"stale"},
  {"id":"machine.disk-lastdb","label":"Disk","L":" ","F":" ","T":"x","why":"full"}
]}}
JSON

export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp.json"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ship.why-stopped-loom' || fail "dry-run json missing why-loom: $out"
printf '%s\n' "$out" | grep -q 'machine.disk-lastdb' || fail "dry-run json missing disk: $out"
printf '%s\n' "$out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("count")==2, d'

empty="$tmp/empty.json"
printf '%s\n' '{"coverage":{"exceptions":[]}}' >"$empty"
WHATS_WRONG_SNAPSHOT_FILE="$empty" empty_out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$empty_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("count")==0, d'

# stand-in heal (no live agent)
WHATS_WRONG_SKIP_BRAIN=1 LOOM_INPUT='{"item":{"id":"x","label":"X"}}' \
  "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh" | grep -q 'stand-in' \
  || fail "heal stand-in missing"

# mechanical load path (no grok)
mech_out="$(
  LOOM_WHATS_WRONG_LIVE=1 WHATS_WRONG_MECHANICAL_ONLY=1 \
    LOOM_INPUT='{"item":{"id":"machine.load","label":"CPU load"}}' \
    "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh"
)"
printf '%s\n' "$mech_out" | grep -q 'mechanical' || fail "mechanical heal missing: $mech_out"
printf '%s\n' "$mech_out" | python3 -c 'import json,sys
d=None
for line in sys.stdin:
    line=line.strip()
    if line.startswith("{") and "heal_status" in line:
        d=json.loads(line)
assert d and d.get("id")=="machine.load" and d.get("heal_status") in ("healed","noop"), d'

# --- no loom → exit 3 ---
set +e
HOME="$tmp" PATH="/usr/bin:/bin" LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp2.json" \
  "$BIN" --json --quiet >"$tmp/noloom.out" 2>"$tmp/noloom.err"
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
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --input) printf '%s\n' "$2" >"${LOOM_CAPTURE_INPUT:?}"; shift 2 ;;
        *) shift ;;
      esac
    done
    cat <<'VIEW'
lx-ww-1
lx-ww-1
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp3.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-test-key"
export LOOM_CAPTURE_INPUT="$tmp/loom-input.json"
set +e
mout="$("$BIN" --json --quiet --no-heal)"
mrc=$?
set -e
[ "$mrc" -eq 0 ] || fail "mock loom exit $mrc: $mout"
printf '%s\n' "$mout" | grep -q '"outcome":"ok"' || fail "json missing outcome=ok: $mout"
printf '%s\n' "$mout" | grep -q 'exceptions=2' || fail "json missing detail: $mout"
printf '%s\n' "$mout" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $mout"
python3 - "$LOOM_CAPTURE_INPUT" <<'PY' || fail "normal loom input lacks snapshot items"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc.get("count") == 2, doc
assert [row.get("id") for row in doc.get("items", [])] == [
    "ship.why-stopped-loom",
    "machine.disk-lastdb",
], doc
PY

# The default Loom bound follows routinesd's actual gate budget and keeps five
# minutes for wrapper closeout. A 10-minute gate therefore gives Loom 300s.
export LOOM_WHATS_WRONG_KEY="whats-wrong-derived-budget-key"
derived_out="$(ROUTINES_GATE_TIMEOUT_MS=600000 "$BIN" --json --no-heal 2>&1)"
printf '%s\n' "$derived_out" | grep -q 'timeout=300s' \
  || fail "loom bound did not derive 300s from a 600s gate: $derived_out"

export WHATS_WRONG_SNAPSHOT_FILE="$empty"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-empty-loom.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-empty-test-key"
export LOOM_CAPTURE_INPUT="$tmp/loom-empty-input.json"
"$BIN" --json --quiet --no-heal >/dev/null
python3 - "$LOOM_CAPTURE_INPUT" <<'PY' || fail "empty loom input lacks an empty items array"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc.get("count") == 0, doc
assert doc.get("items") == [], doc
PY

# --- hung loom child is SIGTERM'd; wrapper still emits ROUTINE_RESULT ---
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    printf 'lx-ww-hang\n'
    printf '%s\n' "$$" >"${HANG_PID_FILE:?}"
    exec sleep 86400
    ;;
  cancel)
    printf '%s\n' "${2:-}" >"${CANCEL_EXEC_FILE:?}"
    printf 'status: cancelled\n'
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-hang.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=1
# The post-bound readback re-attaches to the same hanging mock, so bound it too.
export LAST_STACK_WHATS_WRONG_LOOM_READBACK_SEC=2
export HANG_PID_FILE="$tmp/hang.pid"
export CANCEL_EXEC_FILE="$tmp/cancel-exec"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-hang-key"
hang_start="$(date +%s)"
set +e
hout="$("$BIN" --json --quiet --no-heal)"
hrc=$?
hang_end="$(date +%s)"
set -e
hang_sec=$((hang_end - hang_start))
[ "$hang_sec" -lt 20 ] || fail "hung loom wrapper took ${hang_sec}s, expected <20"
[ "$hrc" -eq 3 ] || fail "hung loom should exit 3, got $hrc out=$hout"
printf '%s\n' "$hout" | grep -q 'ROUTINE_RESULT' || fail "hung loom missing ROUTINE_RESULT: $hout"
printf '%s\n' "$hout" | grep -q 'outcome=error' || fail "hung loom missing outcome=error: $hout"
printf '%s\n' "$hout" | grep -q 'exceptions=2' || fail "hung loom missing exceptions count: $hout"
# A loom that never answers leaves the heal count UNMEASURED. Printing 0 for
# it is what made a working healer read as broken for six days
# (papercut-whats-wrong-loom-780s-healed-zero-20260820) — an unmeasured value
# must not be rendered as a measured one.
printf '%s\n' "$hout" | grep -q 'healed=unknown' || fail "hung loom must report healed=unknown, not a fabricated 0: $hout"
printf '%s\n' "$hout" | grep -q 'readback=unavailable' || fail "hung loom missing readback marker: $hout"
printf '%s\n' "$hout" | grep -q 'loom-timeout=' || fail "hung loom missing timeout marker: $hout"
if [ -f "$tmp/hang.pid" ]; then
  hpid="$(cat "$tmp/hang.pid")"
  if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
    kill -9 "$hpid" 2>/dev/null || true
    fail "hung loom pid $hpid still alive after wrapper"
  fi
else
  fail "hung loom did not write pid file"
fi
[ "$(cat "$CANCEL_EXEC_FILE" 2>/dev/null || true)" = "lx-ww-hang" ] \
  || fail "deadline did not cancel the abandoned loom execution"

# --- bound fires AFTER heals landed → measured healed>=1, outcome=ok ---
# The CLOSEOUT node writes context.detail/context.healed and only runs at the
# end of the graph, so a bounded run has neither. context.heal_results is
# appended per heal agent, which is the only count a bounded run can report.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  show)
    cat <<'VIEW'
lx-ww-partial
status: running
context.heal_results: [{"id":"machine.disk-lastdb","heal_status":"healed"},{"id":"ship.why-stopped-loom","heal_status":"noop"}]
VIEW
    exit 0
    ;;
  cancel) printf 'status: cancelled\n'; exit 0 ;;
  run)
    # First call hangs (the bounded run). The wrapper kills it, then reads the
    # execution back; `--key` is idempotent so this returns the same exec.
    if [ -f "${PARTIAL_MARK:?}" ]; then
      cat <<'VIEW'
lx-ww-partial
status: running
context.heal_results: [{"id":"machine.disk-lastdb","heal_status":"healed"},{"id":"ship.why-stopped-loom","heal_status":"noop"}]
VIEW
      exit 0
    fi
    printf 'started\n' >"$PARTIAL_MARK"
    exec sleep 86400
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-partial.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=1
export LAST_STACK_WHATS_WRONG_LOOM_READBACK_SEC=20
export PARTIAL_MARK="$tmp/partial.mark"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-partial-key"
set +e
pout="$("$BIN" --json --quiet --no-heal)"
prc=$?
set -e
[ "$prc" -eq 0 ] || fail "bound-after-heals should exit 0, got $prc out=$pout"
printf '%s\n' "$pout" | grep -q 'outcome":"ok"' || fail "bound-after-heals must be ok: $pout"
printf '%s\n' "$pout" | grep -q 'healed=1' || fail "bound-after-heals must report the measured heal: $pout"
printf '%s\n' "$pout" | grep -q 'partial=1' || fail "bound-after-heals missing partial marker: $pout"
python3 - "$LAST_STACK_WHATS_WRONG_STAMP" <<'PY' || fail "partial stamp not written as ok"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d.get("outcome") == "ok", d
assert d.get("status") == "timed-out-partial", d
PY
unset PARTIAL_MARK

# --- bound fires with a measured ZERO → still red (no masking) ---
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  show)
    cat <<'VIEW'
lx-ww-stuck
status: running
context.heal_results: []
VIEW
    exit 0
    ;;
  cancel) printf 'status: cancelled\n'; exit 0 ;;
  run)
    if [ -f "${STUCK_MARK:?}" ]; then
      cat <<'VIEW'
lx-ww-stuck
status: running
context.heal_results: []
VIEW
      exit 0
    fi
    printf 'started\n' >"$STUCK_MARK"
    exec sleep 86400
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-stuck.json"
export STUCK_MARK="$tmp/stuck.mark"
export LOOM_WHATS_WRONG_KEY="whats-wrong-stuck-key"
set +e
sout="$("$BIN" --json --quiet --no-heal)"
src=$?
set -e
[ "$src" -eq 3 ] || fail "a genuinely stuck loom must stay red, got exit $src out=$sout"
printf '%s\n' "$sout" | grep -q 'outcome":"error"' || fail "stuck loom must be error: $sout"
printf '%s\n' "$sout" | grep -q 'healed=0' || fail "stuck loom must report the measured zero: $sout"
printf '%s\n' "$sout" | grep -q 'measured=1' || fail "stuck loom must mark the zero as measured: $sout"
unset STUCK_MARK
unset LAST_STACK_WHATS_WRONG_LOOM_READBACK_SEC

# --- a RETRYABLE LastDB answer is retried, not reported as the hour's result ---
# On 2026-08-27 the 18:23Z and 19:23Z passes each died in ~5 s of a 780 s budget
# because `loom run` hit one HTTP 503 persist_queue_full. The node itself
# labelled that answer `"retryable":true` / `retry after drain`, and the wrapper
# retried nothing
# (papercut-whats-wrong-loom-no-retry-on-retryable-lastdb-503).
# `loom run --key` is idempotent, so a retry re-attaches rather than starting a
# second execution.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    if [ "$n" -lt 2 ]; then
      echo 'Error: mutation on LoomAgent -> HTTP 503: {"error":"persist_queue_full","kind":"bytes","message":"persist queue full for schema '"'"'6fcb6bd1'"'"' (bytes); retry after drain","ok":false,"retryable":true}' >&2
      exit 1
    fi
    cat <<'VIEW'
lx-ww-retry
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-retry.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=60
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC=1
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS=3
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
export RUN_COUNT_FILE="$tmp/run-count-retry"
export LOOM_WHATS_WRONG_KEY="whats-wrong-retry-key"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
set +e
rout="$("$BIN" --json --quiet --no-heal)"
rrc=$?
set -e
[ "$rrc" -eq 0 ] || fail "retryable 503 must be retried to success, got exit $rrc out=$rout"
printf '%s\n' "$rout" | grep -q 'outcome":"ok"' || fail "retried run must be ok: $rout"
printf '%s\n' "$rout" | grep -q 'healed=1' || fail "retried run lost the heal detail: $rout"
[ "$(cat "$RUN_COUNT_FILE")" = "2" ] \
  || fail "expected 2 loom run attempts, got $(cat "$RUN_COUNT_FILE")"

# --- the capture-queue 400 is the SAME backpressure, typed differently ---
# On 2026-08-30T08:23Z the pass logged `attempts=3` and then ended
# `loom run failed rc=1 after 1 attempt(s)`. The node answered HTTP 400
# `Invalid data: Storage backend error: mutation capture queue remained full
# for 100ms; retry before local commit` — no 503, no `"retryable": true`, so
# the classifier read a structural reject and stopped. The next block proves a
# bare 400 still is not retried, so this match must be on the message text.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    if [ "$n" -lt 2 ]; then
      echo 'Error: mutation on LoomExecution -> HTTP 400: "Invalid data: Storage backend error: mutation capture queue remained full for 100ms; retry before local commit"' >&2
      exit 1
    fi
    cat <<'VIEW'
lx-ww-capture-queue
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-capture-queue.json"
export RUN_COUNT_FILE="$tmp/run-count-capture-queue"
export LOOM_WHATS_WRONG_KEY="whats-wrong-capture-queue-key"
set +e
cqout="$("$BIN" --json --quiet --no-heal)"
cqrc=$?
set -e
[ "$cqrc" -eq 0 ] || fail "capture-queue 400 must be retried to success, got exit $cqrc out=$cqout"
printf '%s\n' "$cqout" | grep -q 'outcome":"ok"' || fail "retried capture-queue run must be ok: $cqout"
[ "$(cat "$RUN_COUNT_FILE")" = "2" ] \
  || fail "expected 2 loom run attempts on capture-queue 400, got $(cat "$RUN_COUNT_FILE")"

# --- a NON-retryable answer is not thrashed ---
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    echo 'Error: mutation on LoomAgent -> HTTP 400: {"error":"bad_request","ok":false,"retryable":false}' >&2
    exit 1
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-noretry.json"
export RUN_COUNT_FILE="$tmp/run-count-noretry"
export LOOM_WHATS_WRONG_KEY="whats-wrong-noretry-key"
set +e
nrout="$("$BIN" --json --quiet --no-heal)"
nrrc=$?
set -e
[ "$nrrc" -eq 3 ] || fail "non-retryable failure must stay red, got exit $nrrc out=$nrout"
[ "$(cat "$RUN_COUNT_FILE")" = "1" ] \
  || fail "non-retryable failure must not be retried, got $(cat "$RUN_COUNT_FILE") attempts"
printf '%s\n' "$nrout" | grep -q 'attempts=1' \
  || fail "failure detail must report the attempt count: $nrout"

# --- retries share ONE wall-clock deadline; they cannot extend the gate ---
# routines caps a gate_command at GATE_TIMEOUT_CAP_MS regardless of timeout_min,
# so an attempt loop that restarted the budget each time would be killed
# externally and lose its ROUTINE_RESULT trailer entirely.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    printf '%s\n' "$((n + 1))" >"$nfile"
    echo 'Error: HTTP 503: {"error":"persist_queue_full","retryable":true}' >&2
    exit 1
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-budget.json"
export RUN_COUNT_FILE="$tmp/run-count-budget"
export LOOM_WHATS_WRONG_KEY="whats-wrong-budget-key"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=8
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC=1
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS=9
budget_start="$(date +%s)"
set +e
"$BIN" --json --quiet --no-heal >/dev/null 2>&1
set -e
budget_sec=$(( $(date +%s) - budget_start ))
# wallclock-bound-ok: 20s ceiling over an 8s shared deadline (2.5x slack); the
# failing side is 9 retry attempts that do NOT share it, which runs far longer.
[ "$budget_sec" -le 20 ] \
  || fail "retry loop ran ${budget_sec}s against an 8s budget; the deadline is not shared"
unset LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS
unset RUN_COUNT_FILE
unset LAST_STACK_HEARTBEATS_FILE

# --- bound fires on a graph that has not healed yet → readback=live, not
# --- readback=unavailable ---
# 2026-08-27T20:23Z: the pass bounded out at 780 s and reported
# `healed=unknown loom-timeout=780s readback=unavailable`. The readback had in
# fact WORKED — `loom show lx-20260827T202319.881-74483-1` answered rc=0 in
# ~30 ms with `status: running` / `state: GATHER`. The execution simply had
# neither `healed` nor `heal_results` yet, because the graph was still parked
# before its first heal. Reporting that as an unavailable readback sends the
# operator to look for a broken loom and destroys the one fact worth having:
# WHERE the graph is stuck.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  show)
    cat <<'VIEW'
lx-ww-live
status: running
state: GATHER
context.count: 2
VIEW
    exit 0
    ;;
  run)
    # loom prints the execution id, then the graph parks. The wrapper's bound
    # fires, and the id it already saw makes the readback a direct `loom show`.
    printf 'lx-ww-live\n'
    exec sleep 86400
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-live.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=1
export LAST_STACK_WHATS_WRONG_LOOM_READBACK_SEC=5
export LOOM_WHATS_WRONG_KEY="whats-wrong-live-key"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
set +e
lout="$("$BIN" --json --quiet --no-heal)"
lrc_live=$?
set -e
[ "$lrc_live" -eq 3 ] || fail "a still-running bounded graph stays red, got exit $lrc_live out=$lout"
printf '%s\n' "$lout" | grep -q 'readback=live' \
  || fail "a readback that answered must not be reported as unavailable: $lout"
printf '%s\n' "$lout" | grep -q 'exec-status=running' \
  || fail "readback=live must name the execution status: $lout"
printf '%s\n' "$lout" | grep -q 'exec-state=GATHER' \
  || fail "readback=live must name where the graph is parked: $lout"
printf '%s\n' "$lout" | grep -q 'healed=unknown' \
  || fail "an unwritten heal count stays unknown, never a fabricated 0: $lout"
if printf '%s\n' "$lout" | grep -q 'readback=unavailable'; then
  fail "readback=unavailable must not appear when the read worked: $lout"
fi
python3 - "$LAST_STACK_WHATS_WRONG_STAMP" <<'PYLIVE' || fail "live-readback stamp wrong"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d.get("outcome") == "error", d
assert d.get("status") == "timed-out", d
assert d.get("exec_id") == "lx-ww-live", d
PYLIVE
unset LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_READBACK_SEC

# --- drain-aware schedule: persist_queue_full twice then success ---
# The 2026-09-02T20:25Z pass retried at 10 s and died after 30 s of a 780 s
# budget. The shared schedule is 15,45,90,120 (5 attempts). This fixture uses
# 0 s slots so CI does not wait; the wait LINES are the contract. Old code
# defaulted to 3 attempts and a fixed 10 s sleep, so a 4-shed then success
# case (below) fails on the unfixed wrapper.
. "$ROOT/lib/lastdb-retry-schedule.sh"
[ "$(last_stack_lastdb_retry_default_attempts)" = "5" ] \
  || fail "default attempts must be 5, got $(last_stack_lastdb_retry_default_attempts)"
[ "$(last_stack_lastdb_retry_sleep_sec 1)" = "15" ] \
  || fail "schedule slot 1 must be 15s"
[ "$(last_stack_lastdb_retry_sleep_sec 2)" = "45" ] \
  || fail "schedule slot 2 must be 45s"
[ "$(last_stack_lastdb_retry_sleep_sec 3)" = "90" ] \
  || fail "schedule slot 3 must be 90s"
[ "$(last_stack_lastdb_retry_sleep_sec 4)" = "120" ] \
  || fail "schedule slot 4 must be 120s"

cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    if [ "$n" -lt 3 ]; then
      echo 'Error: mutation on LoomAgent -> HTTP 503: {"error":"persist_queue_full","kind":"bytes","message":"persist queue full for schema '"'"'6fcb6bd1'"'"' (bytes); retry after drain","ok":false,"retryable":true}' >&2
      exit 1
    fi
    cat <<'VIEW'
lx-ww-drain
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS
unset LAST_STACK_LASTDB_RETRY_SLEEP_SEC
unset LAST_STACK_LASTDB_RETRY_ATTEMPTS
export LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC="0,0,0,0"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-drain.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=60
export RUN_COUNT_FILE="$tmp/run-count-drain"
export LOOM_WHATS_WRONG_KEY="whats-wrong-drain-key"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
set +e
drain_out="$("$BIN" --json --quiet --no-heal 2>"$tmp/drain.err")"
drain_rc=$?
set -e
[ "$drain_rc" -eq 0 ] || fail "drain schedule must succeed after two persist_queue_full, got exit $drain_rc out=$drain_out err=$(cat "$tmp/drain.err")"
printf '%s\n' "$drain_out" | grep -q 'outcome":"ok"' \
  || fail "drain schedule run must be ok: $drain_out"
[ "$(cat "$RUN_COUNT_FILE")" = "3" ] \
  || fail "expected 3 loom run attempts (2 sheds + success), got $(cat "$RUN_COUNT_FILE")"
wait_lines="$(grep -c 'drain wait attempt=' "$tmp/drain.err" || true)"
[ "$wait_lines" = "2" ] \
  || fail "expected 2 drain wait lines, got $wait_lines err=$(cat "$tmp/drain.err")"
grep -q 'reason=persist_queue_full' "$tmp/drain.err" \
  || fail "drain wait must name persist_queue_full: $(cat "$tmp/drain.err")"
grep -q 'succeeded after 2 drain wait(s)' "$tmp/drain.err" \
  || fail "must log that the drain finished: $(cat "$tmp/drain.err")"

# Four sheds then success needs the new default of 5 attempts. Old default 3
# ends error after three persist_queue_full answers.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    if [ "$n" -lt 5 ]; then
      echo 'Error: HTTP 503: {"error":"persist_queue_full","retryable":true}' >&2
      exit 1
    fi
    cat <<'VIEW'
lx-ww-drain5
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-drain5.json"
export RUN_COUNT_FILE="$tmp/run-count-drain5"
export LOOM_WHATS_WRONG_KEY="whats-wrong-drain5-key"
set +e
d5out="$("$BIN" --json --quiet --no-heal 2>"$tmp/drain5.err")"
d5rc=$?
set -e
[ "$d5rc" -eq 0 ] || fail "default 5 attempts must survive 4 persist_queue_full, got exit $d5rc out=$d5out err=$(cat "$tmp/drain5.err")"
[ "$(cat "$RUN_COUNT_FILE")" = "5" ] \
  || fail "expected 5 loom run attempts, got $(cat "$RUN_COUNT_FILE")"
d5_waits="$(grep -c 'drain wait attempt=' "$tmp/drain5.err" || true)"
[ "$d5_waits" = "4" ] \
  || fail "expected 4 drain wait lines, got $d5_waits err=$(cat "$tmp/drain5.err")"

unset LAST_STACK_LASTDB_RETRY_SCHEDULE_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC
unset RUN_COUNT_FILE

# --- a failing branch must name its own cause, not just its branch label ---
# Both exit-3 paths below used to report one word. `publish-failed` and
# `snapshot-failed` are true and useless: the wrapper HELD the error text
# (loom's stderr, and list_exceptions' own JSON) and dropped it, so nine hours
# of hourly failures escalated to a generic bucket with no cause anywhere.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish)
    echo 'Error: lastdb POST /api/query -> HTTP 400: "Invalid field: schema abc has no field(s): updated_at"' >&2
    exit 1
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-pubfail.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-pubfail-key"
set +e
"$BIN" --json --no-heal >"$tmp/pubfail.out" 2>"$tmp/pubfail.err"
pfrc=$?
set -e
[ "$pfrc" -eq 3 ] || fail "publish failure must exit 3, got $pfrc"
grep -q 'has no field(s): updated_at' "$tmp/pubfail.err" \
  || fail "publish stderr dropped the cause: $(cat "$tmp/pubfail.err")"
python3 - "$tmp/stamp-pubfail.json" <<'PYCHK' || fail "publish stamp dropped the cause"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
det = d.get("detail") or ""
assert det.startswith("publish-failed"), det
assert "has no field(s): updated_at" in det, det
PYCHK

# The snapshot branch holds its cause in a captured variable, not behind a
# redirect, so a sweep for 2>/dev/null misses it. Same requirement.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/no-such-snapshot.json"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-snapfail.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-snapfail-key"
set +e
"$BIN" --json --no-heal >"$tmp/snapfail.out" 2>"$tmp/snapfail.err"
sfrc=$?
set -e
[ "$sfrc" -eq 3 ] || fail "snapshot failure must exit 3, got $sfrc"
grep -q 'no-such-snapshot.json' "$tmp/snapfail.err" \
  || fail "snapshot stderr dropped the cause: $(cat "$tmp/snapfail.err")"
python3 - "$tmp/stamp-snapfail.json" <<'PYCHK' || fail "snapshot stamp dropped the cause"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
det = d.get("detail") or ""
assert det.startswith("snapshot-failed"), det
assert "no-such-snapshot.json" in det, det
PYCHK
unset WHATS_WRONG_SNAPSHOT_FILE

# --- snapshot read timeout is configurable and generous by default ----------
# The dashboard collects from kanban, host-track and LastDB on every request.
# A fixed 45s read turned node backpressure into rc=3 for nine straight hourly
# runs on 2026-09-06 while ten real exceptions went unhealed.
grep -q 'WHATS_WRONG_SNAPSHOT_TIMEOUT_SEC' "$BIN" \
  || fail "snapshot read timeout is not configurable"
python3 - "$BIN" <<'PYCHK' || fail "snapshot default timeout is too tight"
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'WHATS_WRONG_SNAPSHOT_TIMEOUT_SEC:-(\d+)', src)
assert m, "no default for WHATS_WRONG_SNAPSHOT_TIMEOUT_SEC"
assert int(m.group(1)) >= 120, "default %s is below the 120s floor" % m.group(1)
assert "urlopen(req, timeout=45)" not in src, "the fixed 45s read is still there"
PYCHK


# --- loom's OWN drive deadline is retried, and a finished execution is read ---
# `loom run` can exit non-zero while the execution is alive:
#   execution lx-... is incomplete: still `running` at state `CLOSEOUT` after
#   the drive deadline. ... `loom reap --execution lx-...` recovers an
#   unattended one.
# That is not this wrapper's rc=124 bound, so it used to fall to the terminal
# branch: no readback, no reap, no retry, and an EMPTY exec id in the stamp.
# Measured on 2026-09-07: the 02:23Z pass reported error on
# lx-20260907T022306.693-67123-1 at 02:28:25.820Z and that execution reached
# DONE at 02:28:29.991Z — 4 s later, having spent 319 s of a 2400 s budget.
# The 00:23Z pass did the same. `loom run --key` is idempotent, so re-attaching
# is the whole fix.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  reap)
    printf '%s\n' "$*" >>"${REAP_LOG_FILE:?}"
    exit 0
    ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$nfile"
    if [ "$n" -lt 2 ]; then
      echo 'execution lx-ww-incomplete is incomplete: still `running` at state `CLOSEOUT` after the drive deadline. Another worker holds the frontier, or the frontier is unattended — `loom reap --execution lx-ww-incomplete` recovers an unattended one.' >&2
      exit 4
    fi
    cat <<'VIEW'
lx-ww-incomplete
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-incomplete.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=60
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC=1
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS=3
export RUN_COUNT_FILE="$tmp/run-count-incomplete"
export REAP_LOG_FILE="$tmp/reap-incomplete.log"
export LOOM_WHATS_WRONG_KEY="whats-wrong-incomplete-key"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
set +e
iout="$("$BIN" --json --quiet --no-heal)"
irc=$?
set -e
[ "$irc" -eq 0 ] \
  || fail "loom drive deadline must be re-attached, got exit $irc out=$iout"
printf '%s\n' "$iout" | grep -q 'outcome":"ok"' \
  || fail "re-attached run must be ok: $iout"
printf '%s\n' "$iout" | grep -q 'healed=1' \
  || fail "re-attached run lost the heal detail: $iout"
[ "$(cat "$RUN_COUNT_FILE")" = "2" ] \
  || fail "expected 2 loom run attempts, got $(cat "$RUN_COUNT_FILE")"
grep -q 'lx-ww-incomplete' "$REAP_LOG_FILE" \
  || fail "the named execution was not reaped before the re-attach"

# --- every attempt hits the drive deadline, but the execution DID finish ---
# The retry can run out of attempts while the execution reaches DONE in the
# seconds after the last one. Reporting error there is the false red measured
# on 2026-09-07; a bounded `loom show` read is the whole difference.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  reap) exit 0 ;;
  show)
    cat <<'VIEW'
lx-ww-late
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  run)
    nfile="${RUN_COUNT_FILE:?}"
    n=$(cat "$nfile" 2>/dev/null || echo 0)
    printf '%s\n' "$((n + 1))" >"$nfile"
    echo 'execution lx-ww-late is incomplete: still `running` at state `CLOSEOUT` after the drive deadline. Another worker holds the frontier, or the frontier is unattended — `loom reap --execution lx-ww-late` recovers an unattended one.' >&2
    exit 4
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-late.json"
export RUN_COUNT_FILE="$tmp/run-count-late"
export LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS=2
export LOOM_WHATS_WRONG_KEY="whats-wrong-late-key"
set +e
lout="$("$BIN" --json --quiet --no-heal)"
lrc_test=$?
set -e
[ "$lrc_test" -eq 0 ] \
  || fail "a succeeded execution must not be reported red, got exit $lrc_test out=$lout"
printf '%s\n' "$lout" | grep -q 'outcome":"ok"' \
  || fail "readback of a succeeded execution must be ok: $lout"
printf '%s\n' "$lout" | grep -q 'healed=1' \
  || fail "readback lost the heal detail: $lout"

# --- a genuinely stranded execution stays red, and is NAMED in the stamp ---
# Stamping "" left the frontier unowned; the shared reaper had to find 14 such
# whats-wrong executions by sweep at 01:1xZ on 2026-09-07.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  reap) exit 0 ;;
  show)
    cat <<'VIEW'
lx-ww-stuck
status: running
state: GATHER
VIEW
    exit 0
    ;;
  run)
    echo 'execution lx-ww-stuck is incomplete: still `running` at state `GATHER` after the drive deadline. Another worker holds the frontier, or the frontier is unattended — `loom reap --execution lx-ww-stuck` recovers an unattended one.' >&2
    exit 4
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-stuck.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-stuck-key"
set +e
sout="$("$BIN" --json --quiet --no-heal)"
src_test=$?
set -e
[ "$src_test" -eq 3 ] \
  || fail "a stranded execution must stay red, got exit $src_test out=$sout"
printf '%s\n' "$sout" | grep -q 'outcome":"error"' \
  || fail "stranded execution must report error: $sout"
python3 - "$tmp/stamp-stuck.json" <<'PYCHK' || fail "stranded stamp does not name the execution"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
blob = json.dumps(d)
assert "lx-ww-stuck" in blob, d
PYCHK
unset REAP_LOG_FILE
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS

echo "ok"

# --- stop_abandoned_drive_workers -------------------------------------------
#
# The re-attach branch must stop the driver it just gave up on. Before this,
# every `loom run --key` retry started ANOTHER `drive-detached` worker and left
# the previous one alive: five attempts left five live drivers on one execution
# and eleven on its child on 2026-09-07, host load average 42, and the reap
# between attempts answered `reaped` while recovering nothing because those
# live drivers still held the lease.
#
# Three properties, proven against real processes:
#   1. a driver for the named execution is stopped,
#   2. a `drive-detached` CHILD of that driver is stopped too (killing only the
#      parent reparents the child to PID 1, where it survives forever),
#   3. a process that merely QUOTES the marker is NOT signalled. A routine
#      harness carries its whole prompt on its command line, so `claude -p`
#      dispatches match a substring search — four did on 2026-09-07 — and
#      signalling one kills the routine running this wrapper.
LIB="$ROOT/lib/loom-drive-workers.sh"
[ -f "$LIB" ] || fail "lib/loom-drive-workers.sh missing"
bash -n "$LIB" || fail "lib/loom-drive-workers.sh does not parse"
grep -q '\. "\$ROOT/lib/loom-drive-workers.sh"' "$BIN" \
  || fail "whats-wrong wrapper does not source lib/loom-drive-workers.sh"
stop_fn="$(sed -n '/^stop_abandoned_drive_workers()/,/^}$/p' "$LIB")"
[ -n "$stop_fn" ] || fail "stop_abandoned_drive_workers not found in $LIB"
printf '%s\n' "$stop_fn" > "$tmp/stop.sh"
bash -n "$tmp/stop.sh" || fail "stop_abandoned_drive_workers does not parse"

# A stand-in whose argv[0] basename is `loom`, so the helper's binary check
# accepts it. `sh` ignores the trailing words but `ps` still shows them.
mkdir -p "$tmp/fakebin"
ln -s /bin/sh "$tmp/fakebin/loom"

cat > "$tmp/stop-case.sh" <<'CASE'
#!/bin/bash
set -u
. "$1"; FB="$2"
# `sh -c '<simple command>'` execs the command and DROPS the trailing argv,
# which erases the marker `ps` must show. A compound body keeps the shell.
"$FB/loom" -c '"$0" -c "sleep 120; :" "$0" --socket /x drive-detached lx-TEST-CHILD \
    >/dev/null 2>&1 &
  sleep 120; :' "$FB/loom" --socket /x drive-detached lx-TEST-PARENT >/dev/null 2>&1 &
"$FB/loom" -c 'sleep 120; :' d --socket /x drive-detached lx-TEST-OTHER >/dev/null 2>&1 &
/bin/bash -c 'exec -a "harness -p prompt drive-detached lx-TEST-PARENT tail" sleep 120' \
  >/dev/null 2>&1 &
sleep 2
printf 'BEFORE %s\n' "$(ps -Ao command= | grep -c 'drive-detached lx-TEST')"
printf 'ANSWER %s\n' "$(stop_abandoned_drive_workers lx-TEST-PARENT)"
sleep 2
ps -Ao command= | grep 'drive-detached lx-TEST' | grep -v grep | sed 's/^ *//' \
  | while read -r line; do printf 'AFTER %s\n' "$line"; done
kill %1 %2 %3 >/dev/null 2>&1 || true
exit 0
CASE

case_out="$(bash "$tmp/stop-case.sh" "$tmp/stop.sh" "$tmp/fakebin" 2>/dev/null)"
printf '%s\n' "$case_out" | grep -q '^ANSWER stopped=2$' \
  || fail "stop_abandoned_drive_workers did not stop the driver and its child: $case_out"
printf '%s\n' "$case_out" | grep -q 'AFTER.*lx-TEST-OTHER' \
  || fail "stop_abandoned_drive_workers killed an unrelated execution's driver: $case_out"
printf '%s\n' "$case_out" | grep -q 'AFTER.*harness -p prompt' \
  || fail "stop_abandoned_drive_workers signalled a process that only quotes the marker: $case_out"
printf '%s\n' "$case_out" | grep -q 'AFTER.*/loom.*lx-TEST-PARENT' \
  && fail "stop_abandoned_drive_workers left the named driver alive: $case_out"

# No id, and an id loom never named, are both no-ops rather than a broad sweep.
for arg in '' unknown; do
  ans="$(bash -c '. "$1"; stop_abandoned_drive_workers "$2"' _ "$tmp/stop.sh" "$arg")"
  [ "$ans" = "none" ] || fail "stop_abandoned_drive_workers('$arg') answered '$ans', wanted none"
done

# A scheduled routine runs under a sandbox that answers `operation not
# permitted: ps` -- lastdb-canary-dogfood stopped on exactly that on
# 2026-09-06 (papercut-routine-process-inspection-sandbox-denied). These
# wrappers ARE scheduled routines, so this is the production path, not an edge
# case. It must degrade to a named no-op and still return 0, so the reap and
# the retry after it run either way.
mkdir -p "$tmp/denybin"
printf '#!/bin/sh\necho "operation not permitted: ps" >&2\nexit 1\n' > "$tmp/denybin/ps"
chmod 755 "$tmp/denybin/ps"
denied="$(bash -c '. "$1"; PATH="$2:$PATH"; stop_abandoned_drive_workers lx-ANY' \
  _ "$tmp/stop.sh" "$tmp/denybin")"
[ "$denied" = "unreadable" ] \
  || fail "a denied ps should answer 'unreadable', got '$denied'"
bash -c '. "$1"; PATH="$2:$PATH"; stop_abandoned_drive_workers lx-ANY >/dev/null' \
  _ "$tmp/stop.sh" "$tmp/denybin" \
  || fail "a denied ps must still return 0 so the reap and retry run"

# The re-attach branch must call it, and before the reap.
grep -q 'stop_answer="$(stop_abandoned_drive_workers "$stalled_exec")"' "$BIN" \
  || fail "re-attach branch does not stop the abandoned driver"
python3 - "$BIN" <<'ORDER'
import sys
src = open(sys.argv[1]).read()
stop = src.index('stop_answer="$(stop_abandoned_drive_workers "$stalled_exec")"')
reap = src.index('if reap_stalled_execution "$stalled_exec"; then')
assert stop < reap, "the driver must be stopped BEFORE the reap, or the reap finds a held lease"
ORDER
grep -q 'workers=${stop_answer}' "$BIN" \
  || fail "re-attach log line does not report how many drivers were stopped"
