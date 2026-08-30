#!/usr/bin/env bash
# The dashboard wrapper must leave a readable outcome on disk in every case,
# including the one that used to be silent: a caller that loses the tool result.
#
# Card: north-star-dashboard-generator-must-not-exit-silently
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/bin/last-stack-north-star-dashboard-run"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-dashboard-run-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

chmod +x "$RUN"
bash -n "$RUN"

STATUS="$WORK/last-run.env"
HTML="$WORK/dash.html"

get() { sed -n "s/^$1=//p" "$STATUS" | head -1; }

fake_bin() {
  # fake_bin <name> <body...>  -> path to an executable stand-in generator
  local name="$1"; shift
  local path="$WORK/$name"
  printf '%s\n' "$@" >"$path"
  chmod +x "$path"
  printf '%s' "$path"
}

# --- success -----------------------------------------------------------------
ok_bin="$(fake_bin gen-ok '#!/usr/bin/env bash' 'printf "HTML=%s\n" "$3" >&2' 'exit 0')"
printf 'previous\n' >"$HTML"
"$RUN" --bin "$ok_bin" --status-file "$STATUS" --html "$HTML" --timeout 60 2>"$WORK/ok.err"
[ "$(get dashboard_status)" = "ok" ] || { echo "expected status ok, got $(get dashboard_status)" >&2; exit 1; }
[ "$(get dashboard_exit)" = "0" ] || { echo "expected exit 0" >&2; exit 1; }
grep -q '^dashboard_started_at=2' "$STATUS"
grep -q '^dashboard_finished_at=2' "$STATUS"
[ "$(get dashboard_html)" = "$HTML" ]
[ "$(get dashboard_html_bytes)" -gt 0 ]
grep -q 'dashboard_status=ok' "$WORK/ok.err"

# --- failure names what broke -------------------------------------------------
fail_bin="$(fake_bin gen-fail '#!/usr/bin/env bash' 'printf "ERROR=brain put failed (1): node did not respond\n" >&2' 'exit 1')"
set +e
"$RUN" --bin "$fail_bin" --status-file "$STATUS" --html "$HTML" --timeout 60 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "wrapper must exit with the generator status, got $rc" >&2; exit 1; }
[ "$(get dashboard_status)" = "failed" ] || { echo "expected failed" >&2; exit 1; }
[ "$(get dashboard_exit)" = "1" ]
get dashboard_diagnostic | grep -q 'brain put failed' \
  || { echo "diagnostic must name what failed: $(get dashboard_diagnostic)" >&2; exit 1; }

# --- a signalled generator is recorded, not silent ---------------------------
kill_bin="$(fake_bin gen-kill '#!/usr/bin/env bash' 'kill -9 $$')"
set +e
"$RUN" --bin "$kill_bin" --status-file "$STATUS" --html "$HTML" --timeout 60 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 137 ] || { echo "expected 137 for SIGKILL, got $rc" >&2; exit 1; }
[ "$(get dashboard_status)" = "killed" ] || { echo "expected killed, got $(get dashboard_status)" >&2; exit 1; }
[ "$(get dashboard_signal)" = "KILL" ] || { echo "expected SIGKILL named, got $(get dashboard_signal)" >&2; exit 1; }

# --- the command budget is a named outcome, not a guess ----------------------
if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
  slow_bin="$(fake_bin gen-slow '#!/usr/bin/env bash' 'sleep 30')"
  set +e
  "$RUN" --bin "$slow_bin" --status-file "$STATUS" --html "$HTML" --timeout 1 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || { echo "expected 124 on timeout, got $rc" >&2; exit 1; }
  [ "$(get dashboard_status)" = "timeout" ] || { echo "expected timeout" >&2; exit 1; }
fi

# --- the running marker: a hard-killed wrapper still leaves evidence ---------
# SIGKILL the wrapper itself. No trap can run, so the file must still hold the
# marker written BEFORE the generator started. That is the case that used to
# reach the routine as pure silence.
hang_bin="$(fake_bin gen-hang '#!/usr/bin/env bash' 'sleep 30')"
rm -f "$STATUS"
# Job control gives the wrapper its own process group, so one signal reaches the
# wrapper AND the generator it started. Signal the group BEFORE `wait`: `wait`
# reaps the pid, after which the kernel may hand that number to an unrelated
# process, and `kill`/`pkill -P` against a recycled pid hits a stranger.
set -m
"$RUN" --bin "$hang_bin" --status-file "$STATUS" --html "$HTML" --timeout 60 >/dev/null 2>&1 &
wrapper_pid=$!
set +m
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$STATUS" ] && break
  sleep 0.1
done
kill -9 -"$wrapper_pid" 2>/dev/null || kill -9 "$wrapper_pid" 2>/dev/null || true
wait "$wrapper_pid" 2>/dev/null || true
# The generator must not outlive the test. An orphan `sleep 30` here means the
# group kill missed it, which is the leak this block exists to prove absent.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  pgrep -f "$hang_bin" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -f "$hang_bin" >/dev/null 2>&1; then
  pkill -9 -f "$hang_bin" 2>/dev/null || true
  echo "generator survived the wrapper kill: orphaned child left running" >&2
  exit 1
fi
[ -f "$STATUS" ] || { echo "hard-killed wrapper left no status file at all" >&2; exit 1; }
[ "$(get dashboard_status)" = "running" ] \
  || { echo "expected running marker after SIGKILL, got $(get dashboard_status)" >&2; exit 1; }
[ "$(get dashboard_exit)" = "unknown" ]

# --- a missing generator is an outcome too -----------------------------------
set +e
"$RUN" --bin "$WORK/does-not-exist" --status-file "$STATUS" --html "$HTML" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ]
[ "$(get dashboard_status)" = "failed" ]
get dashboard_diagnostic | grep -q 'not executable'

# --- the diagnostic stays one line -------------------------------------------
noisy_bin="$(fake_bin gen-noisy '#!/usr/bin/env bash' 'printf "ERROR=first line\nsecond line\n" >&2' 'exit 1')"
set +e
"$RUN" --bin "$noisy_bin" --status-file "$STATUS" --html "$HTML" --timeout 60 2>/dev/null
set -e
[ "$(grep -c '^dashboard_diagnostic=' "$STATUS")" -eq 1 ]
[ "$(grep -c '^dashboard_status=' "$STATUS")" -eq 1 ]

echo "PASS last-stack-north-star-dashboard-run"
