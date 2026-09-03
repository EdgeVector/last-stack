#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
bash -n "$BIN"
bash -n "$ROOT/lib/canary-loom/loom-canary-step.sh"
bash -n "$ROOT/lib/canary-loom/loom-run-deadline.sh"
[ -f "$ROOT/lib/canary-loom/lastdb-canary-release.json" ] || fail "graph missing"
[ "$(jq -r .version "$ROOT/lib/canary-loom/lastdb-canary-release.json")" = "6" ] \
  || fail "canary graph version did not advance"
# Every node command must survive a launcher that forgot LOOM_SCRIPTS: the
# 2026-08-30 recovery exec died at spawn (exit 127, no recorded output)
# because the env contract was hand-rolled (lx-20260830T122141.772-6345-1).
jq -e '[.states[] | select(.type == "agent") | .command[2], (.check[2]? // empty)]
       | all(contains("${LOOM_SCRIPTS:-"))' \
  "$ROOT/lib/canary-loom/lastdb-canary-release.json" >/dev/null \
  || fail "a canary node command lacks the LOOM_SCRIPTS fallback"
jq -e '[.states[] | select(.type == "agent") | .command[2], (.check[2]? // empty)]
       | all(contains("${LOOM_SCRIPTS:-"))' \
  "$ROOT/lib/canary-loom/lastdb-safe-upgrade.json" >/dev/null \
  || fail "a safe-upgrade node command lacks the LOOM_SCRIPTS fallback"
[ "$(jq -r '.states.RECOVER_LIVE.timeout_sec' "$ROOT/lib/canary-loom/lastdb-canary-release.json")" = "300" ] \
  || fail "RECOVER_LIVE budget must cover a measured 64s healthy pass plus a busy node"
jq -e '.start_at == "DECIDE_ENTRY" and
       .states.DECIDE_ENTRY.map["verified-live"] == "RECOVER_LIVE" and
       .states.DECIDE_ENTRY.default == "BUILD_START" and
       .states.RECOVER_LIVE.next == "LEDGER" and
       .states.RECOVER_LIVE.on_error == "FAILED" and
       .states.DECIDE_A.map.green == "LEDGER" and
       .states.LEDGER.next == "SOAK" and
       .states.LEDGER.effects == "idempotent" and
       .states.DECIDE_RETRY.default == "DECIDE_RETRY_ROUTE" and
       .states.DECIDE_RETRY_ROUTE.map["verified-live"] == "REPORT" and
       .states.DECIDE_RETRY_ROUTE.default == "BUILD_START"' \
  "$ROOT/lib/canary-loom/lastdb-canary-release.json" >/dev/null \
  || fail "green child does not record the dogfood ledger before soak"
grep -q 'stateless LastDB canary v2 reconciler' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch missing v2 reconciler"
if grep -Eq 'last-stack-canary-loom|SOAK_WAIT' "$ROOT/routines/lastdb-canary-soak-watch.md"; then
  fail "soak-watch still invokes the retired release graph"
fi
grep -q 'last-stack-canary-v2-dogfood-gate' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood missing v2 primary action"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export LAST_STACK_CANARY_LOOM_STAMP="$tmp/stamp.json"
export LAST_STACK_CANARY_LOOM_ACTIVE="$tmp/active.json"
# Key discovery asks loom for its own executions. Default the fixture to an
# empty listing so no test reaches the live node.
printf '%s\n' '[]' >"$tmp/discover-empty.json"
export CANARY_LOOM_LIST_FILE="$tmp/discover-empty.json"
# shellcheck source=../lib/canary-loom/loom-run-deadline.sh
. "$ROOT/lib/canary-loom/loom-run-deadline.sh"
[ "$(loom_run_deadline_secs lastdb-safe-upgrade)" = 5400 ] \
  || fail "lastdb-safe-upgrade deadline is not 5400s"
[ "$(loom_run_deadline_secs lastdb-canary-release)" = 5400 ] \
  || fail "lastdb-canary-release deadline is not 5400s (CALL_A child)"
[ -z "$(loom_run_deadline_secs other-graph)" ] \
  || fail "other definitions must keep the loom default"
(
  unset LOOM_RUN_DEADLINE_SECS
  export_loom_run_deadline_for other-graph
  [ -z "${LOOM_RUN_DEADLINE_SECS:-}" ] \
    || fail "other definition received LOOM_RUN_DEADLINE_SECS=${LOOM_RUN_DEADLINE_SECS:-}"
)
(
  unset LOOM_RUN_DEADLINE_SECS
  export_loom_run_deadline_for lastdb-safe-upgrade
  [ "${LOOM_RUN_DEADLINE_SECS:-}" = 5400 ] \
    || fail "lastdb-safe-upgrade export did not set 5400"
)

out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"
printf '%s\n' "$out" | grep -q 'deadline_secs=5400' \
  || fail "dry-run did not stamp the safe-upgrade drive deadline: $out"
out2="$("$BIN" --dry-run --start --oid abc123 --json --quiet)"
printf '%s\n' "$out2" | grep -q 'canary-abc123' || fail "start dry-run missing key: $out2"
out2_retry="$("$BIN" --dry-run --start --oid abc123 --key canary-abc123-retry-1 --json --quiet)"
printf '%s\n' "$out2_retry" | head -1 \
  | jq -e '.key == "canary-abc123-retry-1"' >/dev/null \
  || fail "start dry-run replaced the explicit retry key: $out2_retry"

mock_home="$tmp/home"
mkdir -p "$mock_home/.local/bin"
cat > "$mock_home/.local/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping|publish|validate) exit 0 ;;
  run)
    printf 'env.LOOM_RUN_DEADLINE_SECS=%s cmd=%s\n' \
      "${LOOM_RUN_DEADLINE_SECS:-}" "$*" >>"${FAKE_LOOM_CALLS:?}"
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
  show)
    [ "${2:-}" = lx-recovery-child ] || exit 2
    printf '%s\n' \
      lx-recovery-child \
      'status: succeeded' \
      'state: DONE' \
      "context.candidate: \"${RECOVERY_STAGE:?}/lastdbd\"" \
      'context.cutover: "live"' \
      "context.source_git_oid: \"${RECOVERY_OID:?}\"" \
      'context.verdict: "green"' \
      'context.verify: "live"' \
      "context.version: \"${RECOVERY_VERSION:?}\"" \
      'node CUTOVER#1 succeeded: {"stdout":"PASS"}' \
      'node PROBE#1 succeeded: {"stdout":"PASS"}' \
      'node VERIFY#1 succeeded: {"stdout":"PASS"}'
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
cat > "$mock_home/.local/bin/last-stack-canary-pipeline" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_PIPELINE_CALLS:?}"
printf '%s\n' '{"state":"dogfood_green"}'
SH
chmod 755 "$mock_home/.local/bin/last-stack-canary-pipeline"
export FAKE_PIPELINE_CALLS="$tmp/pipeline.calls"
: >"$FAKE_PIPELINE_CALLS"

recovery_stage="$tmp/recovery-stage"
recovery_current="$mock_home/.lastdb/current"
mkdir -p "$recovery_stage" "$recovery_current"
recovery_oid=0123456789abcdef0123456789abcdef01234567
recovery_version=0.0.0-g012345678
export RECOVERY_STAGE="$recovery_stage"
export RECOVERY_OID="$recovery_oid"
export RECOVERY_VERSION="$recovery_version"
for name in lastdb lastdbd; do
  cat >"$recovery_stage/$name" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '%s\n' '{"running":true,"daemon_status":"running","build_agreement":"agree","cli_build":"$recovery_version","daemon_build":"$recovery_version"}'
else
  printf '%s %s\n' '$name' '$recovery_version'
fi
SH
  chmod 755 "$recovery_stage/$name"
  cp "$recovery_stage/$name" "$recovery_current/$name"
done
cat >"$recovery_stage/manifest.json" <<JSON
{"source_git_oid":"$recovery_oid","lastdb_version":"$recovery_version","lastdbd_version":"$recovery_version","staged_by":"test"}
JSON
recovery_input="$(jq -cn \
  --arg mode verified-live \
  --arg child lx-recovery-child \
  --arg candidate "$recovery_stage/lastdbd" \
  --arg oid "$recovery_oid" \
  --arg version "$recovery_version" \
  '{recovery_mode:$mode,recovery_child_execution:$child,recovery_candidate:$candidate,recovery_source_git_oid:$oid,recovery_version:$version}')"
recovery_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT="$recovery_input" \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" RECOVER_LIVE)"
printf '%s\n' "$recovery_out" | grep -q '"recovery_verified":true' \
  || fail "verified-live recovery did not produce a receipt: $recovery_out"
printf '%s\n' "$recovery_out" | grep -q '"child_status":"green"' \
  || fail "verified-live recovery did not preserve the green child: $recovery_out"
printf '%s\n' "$recovery_out" | grep -q '"recovery_no_mutation":true' \
  || fail "verified-live recovery did not assert its no-mutation route: $recovery_out"
if printf '%s\n' "$recovery_out" | grep -q 'upgrade_jobs'; then
  fail "verified-live recovery exposed an upgrade job: $recovery_out"
fi

recovery_receipt="$(printf '%s' "$recovery_input" | jq \
  '. + {recovery_verified:true,recovery_no_mutation:true,source_git_oid:.recovery_source_git_oid,version:.recovery_version}')"
recovery_ledger_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT="$recovery_receipt" \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER)"
recovery_ledger_sha="$recovery_version-recovery-lx-recovery-child"
printf '%s\n' "$recovery_ledger_out" | grep -q "\"ledger_sha\":\"$recovery_ledger_sha\"" \
  || fail "verified-live ledger did not create a new attempt: $recovery_ledger_out"
grep -q -- "dogfood --sha $recovery_ledger_sha --observed-sha $recovery_version --version $recovery_version --source verified-live-recovery --source-git-oid $recovery_oid" \
  "$FAKE_PIPELINE_CALLS" \
  || fail "verified-live ledger did not preserve the exact live identity"

: >"$FAKE_PIPELINE_CALLS"
PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT="$recovery_receipt" \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER >/dev/null
[ "$(wc -l <"$FAKE_PIPELINE_CALLS" | tr -d ' ')" -eq 1 ] \
  || fail "verified-live ledger retry issued more than one ledger command"

set +e
missing_receipt_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT="$recovery_input" \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER 2>&1)"
missing_receipt_rc=$?
set -e
[ "$missing_receipt_rc" -ne 0 ] \
  || fail "verified-live ledger accepted input without a RECOVER_LIVE receipt"
printf '%s\n' "$missing_receipt_out" | grep -q 'RECOVER_LIVE receipt' \
  || fail "verified-live ledger refusal did not name the missing receipt"

assert_recovery_refused() {
  local label="$1" input_json="$2"
  set +e
  local refusal
  refusal="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
    LOOM_INPUT="$input_json" \
    "$ROOT/lib/canary-loom/loom-canary-step.sh" RECOVER_LIVE 2>&1)"
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label recovery mismatch was accepted"
  printf '%s\n' "$refusal" | grep -q 'RECOVER_LIVE refused' \
    || fail "$label recovery mismatch lacked a refusal: $refusal"
}

assert_recovery_refused missing-child "$(printf '%s' "$recovery_input" | jq 'del(.recovery_child_execution)')"
assert_recovery_refused wrong-child "$(printf '%s' "$recovery_input" | jq '.recovery_child_execution="lx-other-child"')"
assert_recovery_refused wrong-source "$(printf '%s' "$recovery_input" | jq '.recovery_source_git_oid="0123456789abcdef0123456789abcdef01234568"')"
assert_recovery_refused wrong-version "$(printf '%s' "$recovery_input" | jq '.recovery_version="0.0.1-g012345678"')"
assert_recovery_refused wrong-candidate "$(printf '%s' "$recovery_input" | jq '.recovery_candidate="/tmp/missing-lastdbd"')"
printf '# mismatch\n' >>"$recovery_current/lastdbd"
assert_recovery_refused wrong-installed-bytes "$recovery_input"
cp "$recovery_stage/lastdbd" "$recovery_current/lastdbd"

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

# env -u: an ambient LOOM_LIVE in the caller's shell must not turn this
# stand-in into a REAL ledger write (it did, on 2026-08-30).
standin_ledger="$(env -u LOOM_LIVE -u LOOM_CANARY_LIVE \
  LOOM_INPUT='{"source_git_oid":"abc","version":"1.2.3"}' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh" LEDGER)"
printf '%s\n' "$standin_ledger" | grep -q '"ledger_sha":"1.2.3"' \
  || fail "stand-in ledger step did not record the candidate: $standin_ledger"

export LAST_STACK_CANARY_LOOM_STDOUT_LOG="$tmp/loom.stdout.log"
export LAST_STACK_CANARY_LOOM_STDERR_LOG="$tmp/loom.stderr.log"
export FAKE_LOOM_CALLS="$tmp/loom.calls"
: >"$FAKE_LOOM_CALLS"
out3="$(env -u LOOM_RUN_DEADLINE_SECS HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --key canary-test --json --quiet)"
printf '%s\n' "$out3" | head -1 | jq -e '.outcome == "ok" and .execution == "lx-test-canary" and .status == "running" and .deadline_secs == "5400"' >/dev/null \
  || fail "success result missing execution or deadline: $out3"
grep -q 'env.LOOM_RUN_DEADLINE_SECS=5400 cmd=run lastdb-canary-release --key canary-test' \
  "$FAKE_LOOM_CALLS" \
  || fail "lastdb-safe-upgrade child drive did not receive 5400s: $(cat "$FAKE_LOOM_CALLS")"
jq -e '.deadline_secs == "5400"' "$LAST_STACK_CANARY_LOOM_STAMP" >/dev/null \
  || fail "CUTOVER stamp omitted deadline_secs: $(cat "$LAST_STACK_CANARY_LOOM_STAMP")"
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

# An unreadable execution list is uncertain state, not a quiet lane.
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"
set +e
out_unreadable="$(HOME="$mock_home" FAKE_LOOM_MODE=success \
  CANARY_LOOM_LIST_FILE="$tmp/missing-list.json" "$BIN" --json --quiet)"
rc_unreadable=$?
set -e
[ "$rc_unreadable" -eq 3 ] || fail "unreadable list returned $rc_unreadable, expected 3"
printf '%s\n' "$out_unreadable" | head -1 \
  | jq -e '.outcome == "error" and .detail == "loom-list-unreadable"' >/dev/null \
  || fail "unreadable list became an idle no-op: $out_unreadable"

printf '%s\n' '{not-json' >"$tmp/malformed-list.json"
set +e
out_malformed_list="$(HOME="$mock_home" FAKE_LOOM_MODE=success \
  CANARY_LOOM_LIST_FILE="$tmp/malformed-list.json" "$BIN" --json --quiet)"
rc_malformed_list=$?
set -e
[ "$rc_malformed_list" -eq 3 ] || fail "malformed list returned $rc_malformed_list, expected 3"
printf '%s\n' "$out_malformed_list" | head -1 \
  | jq -e '.outcome == "error" and .detail == "loom-list-unreadable"' >/dev/null \
  || fail "malformed list became an idle no-op: $out_malformed_list"

# --- both local files gone, execution still parked: loom holds the key ---
# The key below is hand-made, so no `canary-<oid>` reconstruction finds it.
# lx-20260830T140407.992-49336-1 sat waiting in SOAK_WAIT under exactly this
# shape while two hourly ticks reported the lane idle.
cat >"$tmp/discover-live.json" <<'JSON'
[
  {
    "id": "lx-20260830T120000.000-1-1",
    "definition_name": "lastdb-canary-release",
    "status": "succeeded",
    "state": "DONE",
    "idempotency_key": "canary-oldoid",
    "updated_at": "2026-08-30T12:00:00.000Z"
  },
  {
    "id": "lx-20260830T140407.992-49336-1",
    "definition_name": "lastdb-canary-release",
    "status": "waiting",
    "state": "SOAK_WAIT",
    "idempotency_key": "io-free-closeout-recover-9beb85ca8-v2",
    "updated_at": "2026-08-30T14:04:07.992Z"
  }
]
JSON
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"
: >"$FAKE_LOOM_CALLS"
out_discover="$(HOME="$mock_home" FAKE_LOOM_MODE=success \
  CANARY_LOOM_LIST_FILE="$tmp/discover-live.json" "$BIN" --json --quiet)"
printf '%s\n' "$out_discover" | head -1 \
  | jq -e '.outcome == "ok" and .key == "io-free-closeout-recover-9beb85ca8-v2"' >/dev/null \
  || fail "gate did not adopt the parked execution's key from loom: $out_discover"
grep -q 'run lastdb-canary-release --key io-free-closeout-recover-9beb85ca8-v2' \
  "$FAKE_LOOM_CALLS" \
  || fail "discovered key was not passed to Loom: $(cat "$FAKE_LOOM_CALLS")"

# An `idle` stamp with an empty key must not end the search either.
write_idle_stamp() { printf '%s\n' '{"ts":"2026-08-30T17:00:00Z","status":"idle","key":"","outcome":"noop","detail":"no-key","engine":"loom"}' >"$LAST_STACK_CANARY_LOOM_STAMP"; }
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE"
write_idle_stamp
: >"$FAKE_LOOM_CALLS"
out_after_idle="$(HOME="$mock_home" FAKE_LOOM_MODE=success \
  CANARY_LOOM_LIST_FILE="$tmp/discover-live.json" "$BIN" --json --quiet)"
printf '%s\n' "$out_after_idle" | head -1 \
  | jq -e '.key == "io-free-closeout-recover-9beb85ca8-v2"' >/dev/null \
  || fail "an idle stamp made the no-key state absorbing: $out_after_idle"

# Discovery only adopts a live execution. A terminal-only listing stays idle.
cat >"$tmp/discover-terminal.json" <<'JSON'
[{"id":"lx-20260830T120000.000-1-1","definition_name":"lastdb-canary-release","status":"succeeded","state":"DONE","idempotency_key":"canary-oldoid","updated_at":"2026-08-30T12:00:00.000Z"}]
JSON
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"
: >"$FAKE_LOOM_CALLS"
out_terminal_only="$(HOME="$mock_home" FAKE_LOOM_MODE=success \
  CANARY_LOOM_LIST_FILE="$tmp/discover-terminal.json" "$BIN" --json --quiet)"
printf '%s\n' "$out_terminal_only" | grep -q 'outcome=noop detail=no-key' \
  || fail "a terminal-only listing was adopted as a resume key: $out_terminal_only"
[ ! -s "$FAKE_LOOM_CALLS" ] || fail "terminal-only listing still ran Loom"
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"

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

env -u LOOM_LIVE -u LOOM_CANARY_LIVE \
  LOOM_INPUT='{"main_oid":"abc","max_attempts":3}' "$ROOT/lib/canary-loom/loom-canary-step.sh" PROBE | grep -q 'verdict":"green"' \
  || fail "stand-in probe not green"
echo ok

[ -f "$ROOT/lib/canary-loom/lastdb-safe-upgrade.json" ] || fail "graph A missing"

# --- verified-live recovery: env-contract regression + supported launcher ---

# The node command must find its script through the installed-tree fallback
# when LOOM_SCRIPTS is absent from the launcher env.
mkdir -p "$mock_home/.last-stack/lib"
ln -sfn "$ROOT/lib/canary-loom" "$mock_home/.last-stack/lib/canary-loom"
recover_cmd="$(jq -r '.states.RECOVER_LIVE.command[2]' "$ROOT/lib/canary-loom/lastdb-canary-release.json")"
fallback_out="$(env -u LOOM_SCRIPTS \
  PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" LOOM_LIVE=1 \
  LOOM_INPUT="$recovery_input" \
  bash -c "$recover_cmd")" \
  || fail "RECOVER_LIVE died without LOOM_SCRIPTS in the env"
printf '%s\n' "$fallback_out" | grep -q '"recovery_verified":true' \
  || fail "fallback-path recovery did not verify: $fallback_out"

# The launcher owns the env contract end to end: --recover reads the green
# child receipt and relaunches the graph in verified-live mode.
: >"$FAKE_LOOM_CALLS"
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"
recover_out="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" FAKE_LOOM_MODE=success \
  "$BIN" --recover --child lx-recovery-child --json --quiet)"
printf '%s\n' "$recover_out" | head -1 | jq -e '.outcome == "ok" and .status == "running"' >/dev/null \
  || fail "--recover did not launch: $recover_out"
grep -q 'run lastdb-canary-release --key canary-recover-' "$FAKE_LOOM_CALLS" \
  || fail "--recover did not run the canary graph under a recovery key"
grep -q '"recovery_mode":"verified-live"' "$FAKE_LOOM_CALLS" \
  || fail "--recover input lacks verified-live mode"
grep -q '"recovery_child_execution":"lx-recovery-child"' "$FAKE_LOOM_CALLS" \
  || fail "--recover input lacks the child execution"
grep -q "\"recovery_candidate\":\"$recovery_stage/lastdbd\"" "$FAKE_LOOM_CALLS" \
  || fail "--recover input lacks the candidate from the child receipt"
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"

# An unreadable child is refused before anything launches.
: >"$FAKE_LOOM_CALLS"
set +e
recover_bad="$(PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" FAKE_LOOM_MODE=success \
  "$BIN" --recover --child lx-unknown-child --json --quiet)"
rc_recover_bad=$?
set -e
[ "$rc_recover_bad" -eq 3 ] || fail "--recover with an unreadable child returned $rc_recover_bad, expected 3"
printf '%s\n' "$recover_bad" | grep -q 'recover-child-unreadable' \
  || fail "--recover unreadable child was not named: $recover_bad"
[ ! -s "$FAKE_LOOM_CALLS" ] || fail "--recover launched despite an unreadable child"
rm -f "$LAST_STACK_CANARY_LOOM_ACTIVE" "$LAST_STACK_CANARY_LOOM_STAMP"

# --recover must never run the stand-in lane against a live receipt.
set +e
PATH="$mock_home/.local/bin:$PATH" HOME="$mock_home" \
  "$BIN" --recover --child lx-recovery-child --no-heal --json --quiet >/dev/null 2>&1
rc_recover_standin=$?
set -e
[ "$rc_recover_standin" -eq 2 ] || fail "--recover --no-heal returned $rc_recover_standin, expected usage refusal 2"

echo recover-ok
