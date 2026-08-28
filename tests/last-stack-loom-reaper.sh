#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-loom-reaper.XXXXXX")"
cleanup() { chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

home="$tmp/home"
state="$tmp/state"
plist="$home/Library/LaunchAgents/com.edgevector.loom-reaper.plist"
mkdir -p "$home/.local/bin" "$home/Library/LaunchAgents" "$state"

cat >"$home/.local/bin/loom" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOOM_CALLS:?}"
printf '%s\n' "${MOCK_LOOM_STDERR:-}" >&2
printf '%s\n' '{"scanned":2,"resumed":1,"skipped":1}'
exit "${MOCK_LOOM_RC:-0}"
SH
chmod +x "$home/.local/bin/loom"
export MOCK_LOOM_CALLS="$tmp/loom.calls"
: >"$MOCK_LOOM_CALLS"

run_reaper() {
  HOME="$home" XDG_STATE_HOME="$state" \
    "$ROOT/bin/last-stack-loom-reaper-run"
}

out="$(run_reaper)" || fail "success pass failed"
[ "$(cat "$MOCK_LOOM_CALLS")" = \
  'reap --older-than-secs 300 --resume-limit 1 --resume-timeout-secs 60 --json' ] \
  || fail "unsafe Loom arguments: $(cat "$MOCK_LOOM_CALLS")"
printf '%s\n' "$out" | jq -e \
  --arg loom "$home/.local/bin/loom" \
  '.status == "ok" and .exit_code == 0 and .loom_bin == $loom
   and .report.resumed == 1
   and .command == ["reap","--older-than-secs","300","--resume-limit","1",
     "--resume-timeout-secs","60","--json"]' \
  >/dev/null || fail "bad success result: $out"
jq -e '.status == "ok" and .report.scanned == 2' \
  "$state/last-stack/loom-reaper/result.json" >/dev/null \
  || fail "result file did not preserve the report"

mkdir -p "$state/last-stack/loom-reaper/run.lock"
printf '%s\n' "$$" >"$state/last-stack/loom-reaper/run.lock/owner"
before="$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')"
locked="$(run_reaper)" || fail "locked pass returned failure"
printf '%s\n' "$locked" | jq -e '.status == "locked" and .exit_code == 0' \
  >/dev/null || fail "bad lock result: $locked"
after="$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')"
[ "$before" = "$after" ] || fail "locked pass invoked Loom"
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
