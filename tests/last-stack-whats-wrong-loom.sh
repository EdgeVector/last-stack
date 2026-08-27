#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-whats-wrong-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-whats-wrong-routine"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-list.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-closeout.sh"

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
    printf '%s\n' "$$" >"${HANG_PID_FILE:?}"
    exec sleep 86400
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
[ "$budget_sec" -le 20 ] \
  || fail "retry loop ran ${budget_sec}s against an 8s budget; the deadline is not shared"
unset LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_SLEEP_SEC
unset LAST_STACK_WHATS_WRONG_LOOM_RETRY_ATTEMPTS
unset RUN_COUNT_FILE
unset LAST_STACK_HEARTBEATS_FILE

echo "ok"
