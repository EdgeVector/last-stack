#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-attribution-trailers"
commit="$ROOT/bin/last-stack-git-commit"

# Interactive: no trailers
unset DRIVEN_BY AUTOMATION_ID ROUTINES_RUN_ID ROUTINES_RUN_DIR || true
out="$("$bin")"
[ -z "$out" ] || { echo "expected empty trailers interactively, got: $out" >&2; exit 1; }

# Routine: full trailers
export DRIVEN_BY=routine
export AUTOMATION_ID=last-stack-fkanban-pickup
export ROUTINES_RUN_ID=2026-07-16T12-00-00-000Z
out="$("$bin")"
printf '%s\n' "$out" | grep -qx 'Driven-By: routine'
printf '%s\n' "$out" | grep -qx 'Automation-Id: last-stack-fkanban-pickup'
printf '%s\n' "$out" | grep -qx 'Run-Id: 2026-07-16T12-00-00-000Z'

# Run dir basename fallback
unset ROUTINES_RUN_ID
export ROUTINES_RUN_DIR=/tmp/runs/last-stack-fkanban-pickup/2026-07-16T99-99-99-999Z
out="$("$bin")"
printf '%s\n' "$out" | grep -qx 'Run-Id: 2026-07-16T99-99-99-999Z'

# git-commit wrapper appends trailers (tmpdir repo)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" config user.email "test@example.com"
git -C "$tmp" config user.name "test"
echo hi >"$tmp/f"
git -C "$tmp" add f
export DRIVEN_BY=routine AUTOMATION_ID=last-stack-fkanban-pickup ROUTINES_RUN_ID=run-1
( cd "$tmp" && "$commit" -m "test commit" )
body="$(git -C "$tmp" log -1 --format=%B)"
printf '%s\n' "$body" | grep -q 'Driven-By: routine'
printf '%s\n' "$body" | grep -q 'Automation-Id: last-stack-fkanban-pickup'
printf '%s\n' "$body" | grep -q 'Run-Id: run-1'

# interactive wrapper is pass-through (no trailers required)
unset DRIVEN_BY AUTOMATION_ID ROUTINES_RUN_ID ROUTINES_RUN_DIR
echo bye >>"$tmp/f"
git -C "$tmp" add f
( cd "$tmp" && "$commit" -m "interactive" )
body2="$(git -C "$tmp" log -1 --format=%B)"
printf '%s\n' "$body2" | grep -q 'interactive'
! printf '%s\n' "$body2" | grep -q 'Driven-By: routine'

echo "ok last-stack-attribution-trailers"
