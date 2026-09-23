#!/usr/bin/env bash
# papercut-last-stack-git-commit-c-option-20260922: a leading -C <dir> runs
# the commit in that worktree, in both the routine and the pass-through path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-git-commit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/wt"
git -C "$tmp/wt" config user.email t@t
git -C "$tmp/wt" config user.name t
echo a >"$tmp/wt/a"
git -C "$tmp/wt" add a
cd "$tmp"
# Pass-through (no routine trailers).
env -u DRIVEN_BY "$bin" -C "$tmp/wt" -m "first" >/dev/null
[ "$(git -C "$tmp/wt" log -1 --format=%s)" = first ]
# Routine path (trailers appended).
echo b >"$tmp/wt/b"
git -C "$tmp/wt" add b
DRIVEN_BY=routine AUTOMATION_ID=test-routine "$bin" -C "$tmp/wt" -m "second" >/dev/null
[ "$(git -C "$tmp/wt" log -1 --format=%s)" = second ]
echo "ok last-stack-git-commit-c-option"
