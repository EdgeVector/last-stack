#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-loom-reaper.XXXXXX")"
stale_owner=""
cleanup() {
  [ -z "$stale_owner" ] || kill -TERM "$stale_owner" 2>/dev/null || true
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

home="$tmp/home"
state="$tmp/state"
plist="$home/Library/LaunchAgents/com.edgevector.loom-reaper.plist"
mkdir -p "$home/.local/bin" "$home/Library/LaunchAgents" "$state"

cat >"$home/.local/bin/loom" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOOM_CALLS:?}"
if [ "${MOCK_LOOM_HANG:-0}" -eq 1 ]; then
  sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
  child=$!
  printf '%s\n' "$child" >"${MOCK_LOOM_CHILD_PID_FILE:?}"
  on_term() {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    exit 0
  }
  trap on_term TERM
  while :; do sleep 1; done
fi
printf '%s\n' "${MOCK_LOOM_STDERR:-}" >&2
printf '%s\n' '{"scanned":2,"resumed":1,"skipped":1}'
exit "${MOCK_LOOM_RC:-0}"
SH
chmod +x "$home/.local/bin/loom"
export MOCK_LOOM_CALLS="$tmp/loom.calls"
export MOCK_LOOM_CHILD_PID_FILE="$tmp/loom-child.pid"
: >"$MOCK_LOOM_CALLS"

run_reaper() {
  HOME="$home" XDG_STATE_HOME="$state" \
    "$ROOT/bin/last-stack-loom-reaper-run"
}

out="$(run_reaper)" || fail "success pass failed"
# The default resume limit must stay above the orphan arrival rate; 1 let the
# deferred set grow from 88 to 314 in eight days. The default resume timeout
# must also exceed the real cost of one resume, or the limit buys nothing: at
# 60 s the 2026-09-06T05:02Z pass reported resumed=0 against active=386, and
# the same class of execution reached DONE on the first try at 480 s.
[ "$(cat "$MOCK_LOOM_CALLS")" = \
  'reap --older-than-secs 300 --abandon-after-secs 172800 --resume-limit 6 --resume-timeout-secs 300 --json' ] \
  || fail "unsafe Loom arguments: $(cat "$MOCK_LOOM_CALLS")"
printf '%s\n' "$out" | jq -e \
  --arg loom "$home/.local/bin/loom" \
  '.status == "ok" and .exit_code == 0 and .loom_bin == $loom
   and (.age_secs | type) == "number"
   and .pass_deadline_secs == 1920
   and .orphan_drives_swept == 0
   and .report.resumed == 1
   and .command == ["reap","--older-than-secs","300",
     "--abandon-after-secs","172800","--resume-limit","6",
     "--resume-timeout-secs","300","--json"]' \
  >/dev/null || fail "bad success result: $out"

# The bounds are tunable, and the recorded command must reflect what actually ran.
: >"$MOCK_LOOM_CALLS"
tuned="$(HOME="$home" XDG_STATE_HOME="$state" \
  LAST_STACK_LOOM_REAPER_RESUME_LIMIT=3 \
  LAST_STACK_LOOM_REAPER_RESUME_TIMEOUT_S=15 \
  LAST_STACK_LOOM_REAPER_OLDER_THAN_S=600 \
  LAST_STACK_LOOM_REAPER_ABANDON_AFTER_S=86400 \
  "$ROOT/bin/last-stack-loom-reaper-run")" || fail "tuned pass failed"
[ "$(cat "$MOCK_LOOM_CALLS")" = \
  'reap --older-than-secs 600 --abandon-after-secs 86400 --resume-limit 3 --resume-timeout-secs 15 --json' ] \
  || fail "env overrides ignored: $(cat "$MOCK_LOOM_CALLS")"
printf '%s\n' "$tuned" | jq -e \
  '.command == ["reap","--older-than-secs","600",
     "--abandon-after-secs","86400","--resume-limit","3",
     "--resume-timeout-secs","15","--json"]' \
  >/dev/null || fail "recorded command did not follow the overrides: $tuned"
: >"$MOCK_LOOM_CALLS"
out="$(run_reaper)" || fail "second default pass failed"
jq -e '.status == "ok" and .report.scanned == 2' \
  "$state/last-stack/loom-reaper/result.json" >/dev/null \
  || fail "result file did not preserve the report"

mkdir -p "$state/last-stack/loom-reaper/run.lock"
printf '%s\n' "$$" >"$state/last-stack/loom-reaper/run.lock/owner"
before="$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')"
locked="$(run_reaper)" || fail "locked pass returned failure"
printf '%s\n' "$locked" | jq -e '.status == "locked" and .exit_code == 0' \
  >/dev/null || fail "bad lock result: $locked"
jq -e '.status == "locked" and .age_secs >= 0' \
  "$state/last-stack/loom-reaper/result.json" >/dev/null \
  || fail "locked result was not written with an age"
after="$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')"
[ "$before" = "$after" ] || fail "locked pass invoked Loom"
rm -f "$state/last-stack/loom-reaper/run.lock/owner"
rmdir "$state/last-stack/loom-reaper/run.lock"

# This asserts the DEADLINE (rc 124, the SIGTERM path), not the kill escalation,
# so it must leave the escalation window at the production default of 10s. It
# used to override it to 1s, and the mock's own TERM handshake does not fit in
# one second: the inner `sh -c \'trap "exit 0" TERM; while :; do sleep 1; done\'`
# cannot run its trap until the running `sleep 1` returns. Measured 2026-09-06
# over 8 samples on an idle host: 832, 858, 952, 953, 958, 967, 971, 1014 ms
# against a 1000 ms budget. `timeout` then escalated to SIGKILL and the test
# failed `deadline exit changed from 124 to 137` -- seen twice on this host
# during a four-shard gate run.
set +e
HOME="$home" XDG_STATE_HOME="$state" \
LAST_STACK_LOOM_REAPER_PASS_DEADLINE_S=1 \
MOCK_LOOM_HANG=1 \
  "$ROOT/bin/last-stack-loom-reaper-run" >"$tmp/deadline.out" 2>"$tmp/deadline.err"
deadline_rc=$?
set -e
[ "$deadline_rc" -eq 124 ] || fail "deadline exit changed from 124 to $deadline_rc"
jq -e '
  .status == "deadline" and .exit_code == 124
  and .pass_deadline_secs == 1 and .age_secs >= 1
  and (.orphan_drives_swept | type) == "number"
' "$state/last-stack/loom-reaper/result.json" >/dev/null \
  || fail "deadline result was not recorded"
deadline_child="$(cat "$MOCK_LOOM_CHILD_PID_FILE")"
if kill -0 "$deadline_child" 2>/dev/null; then
  fail "deadline left descendant $deadline_child alive"
fi

mkdir -p "$state/last-stack/loom-reaper/run.lock"
sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
stale_owner=$!
stale_started=$(( $(date -u +%s) - 10 ))
printf '%s %s\n' "$stale_owner" "$stale_started" \
  >"$state/last-stack/loom-reaper/run.lock/owner"
set +e
stuck="$(HOME="$home" XDG_STATE_HOME="$state" \
  LAST_STACK_LOOM_REAPER_PASS_DEADLINE_S=1 \
  "$ROOT/bin/last-stack-loom-reaper-run")"
stuck_rc=$?
set -e
[ "$stuck_rc" -eq 75 ] || fail "stuck lock exit changed from 75 to $stuck_rc"
printf '%s\n' "$stuck" | jq -e \
  --arg owner "$stale_owner" \
  '.status == "stuck" and .exit_code == 75 and .owner_pid == $owner
   and .age_secs >= 10 and .pass_deadline_secs == 1' \
  >/dev/null || fail "bad stuck-lock result: $stuck"
kill -TERM "$stale_owner" 2>/dev/null || true
wait "$stale_owner" 2>/dev/null || true
stale_owner=""
rm -f "$state/last-stack/loom-reaper/run.lock/owner"
rmdir "$state/last-stack/loom-reaper/run.lock"

set +e
MOCK_LOOM_RC=7 MOCK_LOOM_STDERR='fixture failure' run_reaper \
  >"$tmp/fail.out" 2>"$tmp/fail.err"
fail_rc=$?
set -e
[ "$fail_rc" -eq 7 ] || fail "failure exit changed from 7 to $fail_rc"
jq -e '.status == "error" and .exit_code == 7 and (.stderr | contains("fixture failure"))' \
  "$state/last-stack/loom-reaper/result.json" >/dev/null \
  || fail "failure result was not recorded"
grep -q 'fixture failure' "$tmp/fail.err" || fail "failure stderr was hidden"

HOME="$home" \
XDG_STATE_HOME="$state" \
LAST_STACK_PUBLIC_ROOT="$ROOT" \
LAST_STACK_LAUNCHD_DOMAIN=none \
LOOM_REAPER_PLIST="$plist" \
  "$ROOT/bin/last-stack-loom-reaper-install" install >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$plist")" = 3600 ] \
  || fail "LaunchAgent is not hourly"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" \
  = "$ROOT/bin/last-stack-loom-reaper-run" ] \
  || fail "LaunchAgent does not use the stable runner"
install_out="$(
  HOME="$home" XDG_STATE_HOME="$state" \
  LAST_STACK_PUBLIC_ROOT="$ROOT" LAST_STACK_LAUNCHD_DOMAIN=none \
  LOOM_REAPER_PLIST="$plist" \
    "$ROOT/bin/last-stack-loom-reaper-install" install
)"
printf '%s\n' "$install_out" | grep -q 'already current, skipped launchctl' \
  || fail "second install was not idempotent: $install_out"

grep -q 'last-stack-loom-reaper-install' "$ROOT/setup" \
  || fail "setup does not install the Loom reaper"
jq -e '
  .apps[] | select(.app == "last-stack") | .links
  | any(.source == "bin/last-stack-loom-reaper-run"
        and .target == "$HOME/.local/bin/last-stack-loom-reaper-run")
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "Host Track does not link the Loom reaper runner"

echo "ok: hourly Loom reaper command, lock, failure, and installer"
