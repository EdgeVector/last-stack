#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
bash -n "$BIN"
bash -n "$ROOT/lib/canary-loom/loom-canary-step.sh"
[ -f "$ROOT/lib/canary-loom/lastdb-canary-release.json" ] || fail "graph missing"
[ "$(jq -r .version "$ROOT/lib/canary-loom/lastdb-canary-release.json")" = "4" ] \
  || fail "canary graph version did not advance"
jq -e '.states.DECIDE_A.map.green == "LEDGER" and
       .states.LEDGER.next == "SOAK" and
       .states.LEDGER.effects == "idempotent"' \
  "$ROOT/lib/canary-loom/lastdb-canary-release.json" >/dev/null \
  || fail "green child does not record the dogfood ledger before soak"
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch missing loom tick"
if grep -q 'sm tick --definition lastdb-canary-release' "$ROOT/routines/lastdb-canary-soak-watch.md"; then
  fail "soak-watch still ticks the legacy state engine"
fi
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood missing loom start"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export LAST_STACK_CANARY_LOOM_STAMP="$tmp/stamp.json"
export LAST_STACK_CANARY_LOOM_ACTIVE="$tmp/active.json"
out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"
out2="$("$BIN" --dry-run --start --oid abc123 --json --quiet)"
printf '%s\n' "$out2" | grep -q 'canary-abc123' || fail "start dry-run missing key: $out2"

mock_home="$tmp/home"
mkdir -p "$mock_home/.local/bin"
cat > "$mock_home/.local/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping|publish|validate) exit 0 ;;
  run)
    printf '%s\n' "$*" >>"${FAKE_LOOM_CALLS:?}"
    case "${FAKE_LOOM_MODE:-success}" in
      success)
        printf '%s\n' lx-test-canary 'status: running' 'state: BUILD_WAIT'
        ;;
      failed)
        printf '%s\n' lx-test-failed 'status: failed' 'state: FAILED' 'node BUILD_START#1 failed: permission denied'
        ;;
      error)
        printf '%s\n' 'loom transport denied: "state root"' >&2
        exit 9
        ;;
      terminal)
        printf '%s\n' lx-test-terminal 'status: succeeded' 'state: DONE'
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$mock_home/.local/bin/loom"
cat > "$mock_home/.local/bin/sm-canary-release-step" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  BUILD_POLL) printf '%s\n' 'SM_CONTEXT_PATCH:{"build_next":"BUILD_WAIT"}' ;;
  LEDGER) printf '%s\n' 'SM_CONTEXT_PATCH:{"phase_next":"SOAK","ledger_sha":"candidate-sha","source_git_oid":"abc","version":"1.2.3"}' ;;
  SOAK) printf '%s\n' 'SM_CONTEXT_PATCH:{"soak_status":"pending"}' ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$mock_home/.local/bin/sm-canary-release-step"

# Every external poll changes its context input. Loom then cannot adopt the
# prior successful result when the graph returns from its timed wait.
poll_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT='{"build_poll_revision":7}' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" BUILD_POLL)"
printf '%s\n' "$poll_out" | grep -q 'LOOM_CONTEXT_PATCH:{"build_next":"BUILD_WAIT","build_poll_revision":8}' \
  || fail "live build poll did not store its decision with its revision: $poll_out"
[ "$(printf '%s\n' "$poll_out" | grep -c '^LOOM_CONTEXT_PATCH:')" -eq 1 ] \
  || fail "live build poll emitted split context patches: $poll_out"
soak_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT='{"soak_poll_revision":11}' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" SOAK)"
printf '%s\n' "$soak_out" | grep -q 'LOOM_CONTEXT_PATCH:{"soak_status":"pending","soak_poll_revision":12}' \
  || fail "live soak poll did not store its decision with its revision: $soak_out"
[ "$(printf '%s\n' "$soak_out" | grep -c '^LOOM_CONTEXT_PATCH:')" -eq 1 ] \
  || fail "live soak poll emitted split context patches: $soak_out"
ledger_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT='{"source_git_oid":"abc","version":"1.2.3"}' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER)"
printf '%s\n' "$ledger_out" | grep -q 'LOOM_CONTEXT_PATCH:{"phase_next":"SOAK","ledger_sha":"candidate-sha","source_git_oid":"abc","version":"1.2.3"}' \
  || fail "live ledger step did not preserve the dogfood receipt: $ledger_out"

standin_ledger="$(LOOM_INPUT='{"source_git_oid":"abc","version":"1.2.3"}' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER)"
printf '%s\n' "$standin_ledger" | grep -q '"ledger_sha":"1.2.3"' \
  || fail "stand-in ledger step did not record the candidate: $standin_ledger"

export LAST_STACK_CANARY_LOOM_STDOUT_LOG="$tmp/loom.stdout.log"
export LAST_STACK_CANARY_LOOM_STDERR_LOG="$tmp/loom.stderr.log"
export FAKE_LOOM_CALLS="$tmp/loom.calls"
: >"$FAKE_LOOM_CALLS"
out3="$(HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --key canary-test --json --quiet)"
printf '%s\n' "$out3" | head -1 | jq -e '.outcome == "ok" and .execution == "lx-test-canary" and .status == "running"' >/dev/null \
  || fail "success result missing execution: $out3"
grep -q 'state: BUILD_WAIT' "$LAST_STACK_CANARY_LOOM_STDOUT_LOG" \
  || fail "loom stdout was not preserved"
jq -e '.key == "canary-test" and .execution == "lx-test-canary" and .status == "running"' \
  "$LAST_STACK_CANARY_LOOM_ACTIVE" >/dev/null \
  || fail "active execution marker was not written"

# Losing the mutable last-result stamp must not lose the native Loom resume key.
rm -f "$LAST_STACK_CANARY_LOOM_STAMP"
: >"$FAKE_LOOM_CALLS"
out_resume="$(HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --json --quiet)"
printf '%s\n' "$out_resume" | head -1 | jq -e '.outcome == "ok" and .key == "canary-test"' >/dev/null \
  || fail "active marker did not recover the resume key: $out_resume"
grep -q 'run lastdb-canary-release --key canary-test' "$FAKE_LOOM_CALLS" \
  || fail "recovered key was not passed to Loom"

# A terminal execution clears the active marker. A later tick is a true idle noop.
HOME="$mock_home" FAKE_LOOM_MODE=terminal "$BIN" --key canary-test --json --quiet >/dev/null
[ ! -e "$LAST_STACK_CANARY_LOOM_ACTIVE" ] || fail "terminal execution left an active marker"
rm -f "$LAST_STACK_CANARY_LOOM_STAMP"
: >"$FAKE_LOOM_CALLS"
out_idle="$(HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --json --quiet)"
printf '%s\n' "$out_idle" | grep -q 'outcome=noop detail=no-key' \
  || fail "true idle lane did not return no-key: $out_idle"
[ ! -s "$FAKE_LOOM_CALLS" ] || fail "idle lane called Loom without a resume key"

# A damaged active marker is an error. It must not look like a true idle lane.
printf '%s\n' '{"status":"running","key":""}' >"$LAST_STACK_CANARY_LOOM_ACTIVE"
set +e
out_invalid="$(HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --json --quiet)"
rc_invalid=$?
set -e
[ "$rc_invalid" -eq 3 ] || fail "invalid active marker returned $rc_invalid, expected 3"
printf '%s\n' "$out_invalid" | head -1 | jq -e '.outcome == "error" and .detail == "active-marker-invalid"' >/dev/null \
  || fail "invalid active marker was not structured: $out_invalid"
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE"

set +e
out4="$(HOME="$mock_home" FAKE_LOOM_MODE=failed "$BIN" --key canary-failed --json --quiet)"
rc4=$?
set -e
[ "$rc4" -eq 3 ] || fail "failed loom status returned $rc4, expected 3"
printf '%s\n' "$out4" | head -1 | jq -e '.outcome == "error" and .execution == "lx-test-failed" and .status == "failed"' >/dev/null \
  || fail "failed result missing execution: $out4"

set +e
out5="$(HOME="$mock_home" FAKE_LOOM_MODE=error "$BIN" --key canary-error --json --quiet)"
rc5=$?
set -e
[ "$rc5" -eq 3 ] || fail "loom command error returned $rc5, expected 3"
printf '%s\n' "$out5" | head -1 | jq -e '.outcome == "error" and .execution == "" and .status == "unknown" and (.detail | contains("loom_rc=9"))' >/dev/null \
  || fail "command error was not structured: $out5"
grep -q 'loom transport denied' "$LAST_STACK_CANARY_LOOM_STDERR_LOG" \
  || fail "loom stderr was not preserved"
grep -q 'loom transport denied' "$LAST_STACK_CANARY_LOOM_STAMP" \
  || fail "loom stderr was not summarized in the stamp"

LOOM_INPUT='{"main_oid":"abc","max_attempts":3}' "$ROOT/lib/canary-loom/loom-canary-step.sh" PROBE | grep -q 'verdict":"green"' \
  || fail "stand-in probe not green"
echo ok

[ -f "$ROOT/lib/canary-loom/lastdb-safe-upgrade.json" ] || fail "graph A missing"
