#!/usr/bin/env bash
# Unit tests for the llms.txt install smoke's bounded quick-try block.
# No isolated node, no install — pure helper behaviour plus wiring greps.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$ROOT/skills/llms-txt-install-smoke/lib-bounded.sh"
RUN="$ROOT/skills/llms-txt-install-smoke/run.sh"
WRAPPER="$ROOT/skills/llms-txt-install-smoke/routine-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail "missing $LIB"
[ -f "$RUN" ] || fail "missing $RUN"
[ -f "$WRAPPER" ] || fail "missing $WRAPPER"
bash -n "$LIB"
bash -n "$RUN"
bash -n "$WRAPPER"

# --- run_bounded: coreutils path and pure-bash watchdog path ----------------
# Both paths must behave the same, so the smoke is bounded on a host with no
# timeout binary too (stock macOS ships neither timeout nor gtimeout).
for mode in auto fallback; do
  if [ "$mode" = fallback ]; then
    export SMOKE_TIMEOUT_BIN=""
  else
    unset SMOKE_TIMEOUT_BIN || true
  fi
  # shellcheck source=../skills/llms-txt-install-smoke/lib-bounded.sh
  . "$LIB"

  # a hang is cut off at the bound and reported as 124
  started="$(date +%s)"
  set +e
  run_bounded 2 sleep 30
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 124 ] || fail "[$mode] hung command must return 124; got $rc"
  [ "$elapsed" -lt 20 ] || fail "[$mode] bound did not fire: ${elapsed}s elapsed"

  # a fast success passes its own status through
  set +e
  run_bounded 10 true
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "[$mode] successful command must return 0; got $rc"

  # a fast failure passes its own status through, not 124
  set +e
  run_bounded 10 sh -c 'exit 7'
  rc=$?
  set -e
  [ "$rc" -eq 7 ] || fail "[$mode] failing command must return 7; got $rc"

  # stdout still reaches the caller through command substitution
  out="$(run_bounded 10 printf 'first note\n')"
  [ "$out" = "first note" ] || fail "[$mode] output not captured; got '$out'"
done
unset SMOKE_TIMEOUT_BIN || true

# --- fail_steps_summary -----------------------------------------------------
. "$LIB"
got="$(fail_steps_summary "brain:ask-or-search timeout=60s (ask_rc=124)" "search:init exit=1")"
[ "$got" = "brain:ask-or-search,search:init" ] || fail "summary join wrong; got '$got'"
got="$(fail_steps_summary "brain:get-hello" "brain:get-hello timeout=60s")"
[ "$got" = "brain:get-hello" ] || fail "summary must dedupe; got '$got'"
got="$(fail_steps_summary)"
[ -z "$got" ] || fail "empty summary must be empty; got '$got'"

# --- preserve_failure_log ---------------------------------------------------
log_tmp="$(mktemp -d "${TMPDIR:-/tmp}/llms-smoke-log-test.XXXXXX")"
printf 'install-apps failed at clone\n' >"$log_tmp/source.log"
preserve_failure_log "$log_tmp/source.log" "$log_tmp/preserved.log" \
  || fail "failure log copy returned nonzero"
grep -qF 'install-apps failed at clone' "$log_tmp/preserved.log" \
  || fail "failure log copy lost the detailed output"
if preserve_failure_log "$log_tmp/missing.log" "$log_tmp/unexpected.log"; then
  fail "missing source log must return nonzero"
fi
rm -rf "$log_tmp"

# --- run.sh wiring: every quick-try call is bounded -------------------------
# The bound is clamped to the global budget, so the literal is the
# smoke_bounded_remaining form rather than a bare QUICK_TRY_TIMEOUT.
for call in \
  'run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" search init --quiet' \
  'run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain concept new hello' \
  'run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain get hello' \
  'run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain ask' \
  'run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain search'
do
  grep -qF "$call" "$RUN" || fail "quick-try call not bounded in run.sh: $call"
done

# A bare QUICK_TRY_TIMEOUT bound would run past the global deadline.
if grep -qF 'run_bounded "$QUICK_TRY_TIMEOUT"' "$RUN"; then
  fail "quick-try bound must be clamped by smoke_bounded_remaining"
fi

# No unbounded survivor: the quick-try verbs must never be invoked bare in
# run.sh. Scoped to the quick-try verbs only — `brain init --grant-consent` and
# the rest of the install section are deliberately out of scope.
while IFS= read -r line; do
  # strip the `NNN:` grep prefix and leading indent before classifying
  body="${line#*:}"
  body="$(printf '%s' "$body" | sed 's/^[[:space:]]*//')"
  case "$body" in
    \#*|echo\ *|printf\ *) continue ;;   # diagnostics, not invocations
  esac
  case "$line" in
    *run_bounded*) continue ;;
    *command\ -v*) continue ;;
  esac
  fail "unbounded quick-try invocation in run.sh: $line"
done <<EOF
$(grep -nE '(^|[^-[:alnum:]_])(brain (ask|search|get|concept)|search init)' "$RUN" || true)
EOF

# --- global deadline helpers ------------------------------------------------
# Per-call bounds alone cannot keep N calls under one foreground cap. The
# global budget is what makes the run always reach a VERDICT.
. "$LIB"

smoke_deadline_init 0
[ "$(smoke_remaining)" -eq 999999 ] || fail "disabled deadline must not clamp"
[ "$(smoke_bounded_remaining 60)" -eq 60 ] \
  || fail "disabled deadline must pass the requested bound through"
if smoke_deadline_exceeded; then fail "disabled deadline must never read exceeded"; fi

smoke_deadline_init 100
remaining="$(smoke_remaining)"
[ "$remaining" -le 100 ] && [ "$remaining" -ge 95 ] \
  || fail "fresh 100s budget should report ~100s left; got $remaining"
[ "$(smoke_bounded_remaining 30)" -eq 30 ] \
  || fail "a bound under the budget passes through unchanged"
[ "$(smoke_bounded_remaining 5000)" -le 100 ] \
  || fail "a bound over the budget must be clamped to what is left"
if smoke_deadline_exceeded; then fail "fresh budget must not read exceeded"; fi

# A spent budget floors every later bound so the tail fails fast and the
# footer is still reached.
SMOKE_STARTED_EPOCH=$(( $(date +%s) - 500 ))
smoke_deadline_exceeded || fail "spent budget must read exceeded"
[ "$(smoke_remaining)" -eq 0 ] || fail "spent budget must report 0 left"
[ "$(smoke_bounded_remaining 120)" -eq "${SMOKE_MIN_BOUND:-1}" ] \
  || fail "spent budget must floor the bound, never return 0 or negative"
unset SMOKE_STARTED_EPOCH SMOKE_TOTAL_BUDGET || true

# --- run.sh wiring: the previously unbounded steps are bounded now ----------
# `brain init` is where the 2026-08-29 run died with no verdict.
for call in \
  'bounded_step "clone:last-stack" "$INSTALL_TIMEOUT"' \
  'bounded_step "setup" "$INSTALL_TIMEOUT"' \
  'bounded_step "install-apps" "$INSTALL_TIMEOUT"' \
  'bounded_step "brain:init" "$APP_INIT_TIMEOUT"' \
  'bounded_step "kanban:init" "$APP_INIT_TIMEOUT"' \
  'bounded_step "kanban:list" "$APP_INIT_TIMEOUT"' \
  'bounded_step "situations:init" "$APP_INIT_TIMEOUT"' \
  'bounded_step "situations:list" "$APP_INIT_TIMEOUT"'
do
  grep -qF "$call" "$RUN" || fail "install/init call not bounded in run.sh: $call"
done

grep -qF 'smoke_deadline_init "$SMOKE_TOTAL_BUDGET_SECS"' "$RUN" \
  || fail "run.sh must arm the global deadline"

# The budget must leave footer margin under the agent tool's 600s cap.
budget_default="$(sed -n 's/^SMOKE_TOTAL_BUDGET_SECS="\${SMOKE_TOTAL_BUDGET_SECS:-\([0-9]*\)}"$/\1/p' "$RUN")"
[ -n "$budget_default" ] || fail "could not read the default global budget from run.sh"
[ "$budget_default" -le 570 ] \
  || fail "global budget $budget_default leaves no footer margin under the 600s cap"

# No bare unbounded init survivor. Anchored at line start (optional indent) so
# the usage heredoc's prose — "runs brain/kanban/situations init + quick try" —
# is not read as an invocation.
while IFS= read -r line; do
  # A grep with no hits still feeds one empty line through the heredoc.
  [ -n "$line" ] || continue
  case "$line" in
    *bounded_step*|*run_bounded*|*command\ -v*) continue ;;
  esac
  fail "unbounded init invocation in run.sh: $line"
done <<EOF
$(grep -nE '^[[:space:]]*(brain|kanban|situations) init([[:space:]]|$)' "$RUN" || true)
EOF

# --- run.sh breadcrumbs reach the REAL stderr, not just the sandbox log -----
# `exec >>"$LOG" 2>&1` means a killed run leaves the caller nothing unless the
# step markers go to fd 4. That is why the 08-29 kill had to be reconstructed
# from a leftover sandbox directory.
grep -qF 'live() { echo "$*" >&4; echo "$*"; }' "$RUN" \
  || fail "run.sh must mirror breadcrumbs to the real stderr on fd 4"
for helper in \
  'step() { live "[$(smoke_elapsed)s] >>> $1"; }' \
  'note_pass() { PASS+=("$1"); live "[$(smoke_elapsed)s]   OK  $1"; }' \
  'note_fail() { FAILS+=("$1"); live "[$(smoke_elapsed)s]   FAIL $1"; }'
do
  grep -qF "$helper" "$RUN" || fail "breadcrumb helper missing or unstamped: $helper"
done
if grep -qE '^echo ">>>' "$RUN"; then
  fail "step markers must use step(), which reaches the real stderr"
fi

# --- run.sh footer: RED names the step, on the visible status stream --------
grep -qF 'emit_status "VERDICT: RED ${FAIL_STEPS}"' "$RUN" \
  || fail "RED verdict must name the failing step on the status stream"
grep -qF 'emit_status "FAIL (${#FAILS[@]}): ${FAILS[*]:-none}"' "$RUN" \
  || fail "FAIL footer must reach the status stream for routine-run.sh"
grep -qF 'preserve_failure_log "$LOG" "$LLMS_TXT_SMOKE_FAILURE_LOG"' "$RUN" \
  || fail "run.sh must copy the detailed RED log before sandbox cleanup"

# --- wrapper: GREEN match is anchored, RED verdict with steps still parses ---
grep -qF "grep -q '^VERDICT: GREEN'" "$WRAPPER" \
  || fail "wrapper GREEN match must be anchored"
grep -qF 'LLMS_TXT_SMOKE_FAILURE_LOG="$FAILURE_LOG"' "$WRAPPER" \
  || fail "wrapper must pass a durable failure-log destination to run.sh"
grep -qF 'failure log preserved at $FAILURE_LOG' "$WRAPPER" \
  || fail "wrapper must report the durable failure-log path"
printf 'VERDICT: RED brain:ask-or-search\n' \
  | grep -qE '^VERDICT: (GREEN|RED)' \
  || fail "wrapper verdict grep must still match a RED line carrying steps"

# A RED wrapper run keeps the detailed log in the routine run directory.
wrapper_tmp="$(mktemp -d "${TMPDIR:-/tmp}/llms-smoke-wrapper-test.XXXXXX")"
mkdir -p "$wrapper_tmp/run"
cp "$WRAPPER" "$wrapper_tmp/routine-run.sh"
cat >"$wrapper_tmp/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install-apps clone failed\n' >"${LLMS_TXT_SMOKE_FAILURE_LOG:?}"
printf '{"verdict":"RED","steps":"install-apps"}\n'
printf 'FAIL (1): install-apps exit=1\n' >&2
printf 'VERDICT: RED install-apps\n' >&2
exit 1
EOF
chmod +x "$wrapper_tmp/run.sh"
set +e
ROUTINES_RUN_DIR="$wrapper_tmp/run" TMPDIR="$wrapper_tmp/run" \
  bash "$wrapper_tmp/routine-run.sh" \
  >"$wrapper_tmp/wrapper.stdout" 2>"$wrapper_tmp/wrapper.stderr"
wrapper_rc=$?
set -e
[ "$wrapper_rc" -eq 1 ] || fail "RED wrapper must exit 1; got $wrapper_rc"
grep -qF 'install-apps clone failed' "$wrapper_tmp/run/smoke-run.log" \
  || fail "RED wrapper did not retain the detailed log"
grep -qF "failure log preserved at $wrapper_tmp/run/smoke-run.log" \
  "$wrapper_tmp/wrapper.stderr" \
  || fail "RED wrapper did not report the retained log path"
rm -rf "$wrapper_tmp"

echo "OK llms-txt-install-smoke-bounded"
