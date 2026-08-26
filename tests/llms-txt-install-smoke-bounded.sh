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

# --- run.sh wiring: every quick-try call is bounded -------------------------
for call in \
  'run_bounded "$QUICK_TRY_TIMEOUT" search init --quiet' \
  'run_bounded "$QUICK_TRY_TIMEOUT" brain concept new hello' \
  'run_bounded "$QUICK_TRY_TIMEOUT" brain get hello' \
  'run_bounded "$QUICK_TRY_TIMEOUT" brain ask' \
  'run_bounded "$QUICK_TRY_TIMEOUT" brain search'
do
  grep -qF "$call" "$RUN" || fail "quick-try call not bounded in run.sh: $call"
done

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

# --- run.sh footer: RED names the step, on the visible status stream --------
grep -qF 'emit_status "VERDICT: RED ${FAIL_STEPS}"' "$RUN" \
  || fail "RED verdict must name the failing step on the status stream"
grep -qF 'emit_status "FAIL (${#FAILS[@]}): ${FAILS[*]:-none}"' "$RUN" \
  || fail "FAIL footer must reach the status stream for routine-run.sh"

# --- wrapper: GREEN match is anchored, RED verdict with steps still parses ---
grep -qF "grep -q '^VERDICT: GREEN'" "$WRAPPER" \
  || fail "wrapper GREEN match must be anchored"
printf 'VERDICT: RED brain:ask-or-search\n' \
  | grep -qE '^VERDICT: (GREEN|RED)' \
  || fail "wrapper verdict grep must still match a RED line carrying steps"

echo "OK llms-txt-install-smoke-bounded"
