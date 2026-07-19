#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

workspace="$tmp/workspace"
repo="$workspace/demo"
origin="$tmp/origin.git"
dest="$tmp/kanban-worktrees"
mkdir -p "$workspace"

git -c init.defaultBranch=main init --bare "$origin" >/dev/null
git clone "$origin" "$repo" >/dev/null 2>&1
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
printf 'one\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m initial >/dev/null
git -C "$repo" push -u origin HEAD:main >/dev/null 2>&1

git -C "$repo" worktree add "$repo/.worktrees/clean-slice" -b clean-slice main >/dev/null 2>&1
git -C "$repo" worktree add "$repo/.worktrees/dirty-slice" -b dirty-slice main >/dev/null 2>&1
printf 'dirty\n' > "$repo/.worktrees/dirty-slice/dirty.txt"

out="$("$ROOT/bin/last-stack-migrate-repo-local-worktrees" --workspace "$workspace" --dest "$dest")"
printf '%s\n' "$out" | grep -q 'migrated clean-slice'
printf '%s\n' "$out" | grep -q 'kept dirty-slice: dirty worktree'

test -d "$dest/clean-slice"
test ! -e "$repo/.worktrees/clean-slice"
test -d "$repo/.worktrees/dirty-slice"

common_repo="$(git -C "$repo" rev-parse --git-common-dir)"
common_moved="$(git -C "$dest/clean-slice" rev-parse --git-common-dir)"
case "$common_moved" in
  /*) moved_abs="$common_moved" ;;
  *) moved_abs="$(cd "$dest/clean-slice/$common_moved" && pwd -P)" ;;
esac
case "$common_repo" in
  /*) repo_abs="$common_repo" ;;
  *) repo_abs="$(cd "$repo/$common_repo" && pwd -P)" ;;
esac
test "$moved_abs" = "$repo_abs"

echo "ok"
