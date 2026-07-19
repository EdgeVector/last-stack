#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

ws="$tmp/ws"
repo="$ws/example"
mkdir -p "$repo/.worktrees/abandoned"

git -C "$repo" init --quiet
git -C "$repo" config user.name "Last Stack Test"
git -C "$repo" config user.email "last-stack-test@example.invalid"
printf 'ok\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit --quiet -m "init"
git -C "$repo" remote add origin "$tmp/origin.git"

out="$(REPARK_WORKSPACE="$ws" "$ROOT/bin/last-stack-repark-shared-checkouts" --dry-run)"
case "$out" in
  *"FLAG example"*"repo-local .worktrees present"*"~/.fkanban/worktrees"*) ;;
  *)
    printf '%s\n' "$out" >&2
    echo "expected repo-local .worktrees guard in repark output" >&2
    exit 1
    ;;
esac

echo "ok last-stack-repark-shared-checkouts"
