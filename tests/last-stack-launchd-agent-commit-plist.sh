#!/usr/bin/env bash
# last_stack_agent_commit_plist must create the LaunchAgents directory
# before it moves the rendered plist into place. A real login home always
# has ~/Library/LaunchAgents; the isolated llms-txt-install-smoke HOME does
# not, and the bare `mv -f` there failed "No such file or directory" for
# every one of the function's 9 callers (measured 2026-09-28).
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=../lib/last-stack-launchd-agent.sh
. lib/last-stack-launchd-agent.sh

tmp="$(mktemp -d "${TMPDIR:-/tmp}/launchd-commit-plist.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Never touch a real launchd from this test.
export LAST_STACK_LAUNCHD_DOMAIN=none

echo "== dest dir does not exist yet =="
rendered="$tmp/rendered1.plist"
printf 'one\n' >"$rendered"
dest="$tmp/no-such-dir/LaunchAgents/com.example.test.plist"
last_stack_agent_commit_plist com.example.test "$dest" "$rendered" "test agent" \
  || { echo "commit_plist must succeed when the parent dir is missing"; exit 1; }
[ -f "$dest" ] || { echo "plist was not written to $dest"; exit 1; }
[ "$(cat "$dest")" = one ] || { echo "wrong content: $(cat "$dest")"; exit 1; }

echo "== unchanged content skips the write and keeps the file =="
rendered2="$tmp/rendered2.plist"
printf 'one\n' >"$rendered2"
out="$(last_stack_agent_commit_plist com.example.test "$dest" "$rendered2" "test agent")"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || { echo "expected the skip message, got: $out"; exit 1; }
[ ! -f "$rendered2" ] || { echo "the rendered temp file should be removed"; exit 1; }

echo "== changed content overwrites =="
rendered3="$tmp/rendered3.plist"
printf 'two\n' >"$rendered3"
last_stack_agent_commit_plist com.example.test "$dest" "$rendered3" "test agent" >/dev/null
[ "$(cat "$dest")" = two ] || { echo "expected updated content, got: $(cat "$dest")"; exit 1; }

echo "last-stack-launchd-agent-commit-plist: PASS"
