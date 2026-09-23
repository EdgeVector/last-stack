#!/usr/bin/env bash
# papercut-worktree-reclaim-resolves-mirror-worktree-repo-to-cache-root-20260923
#
# A portal worktree's git common dir is a bare mirror
# (~/.cache/edgevector-git/<repo>.git). resolve_repo must return the mirror,
# not the cache root, and removal must go through `git worktree remove` in the
# mirror so no stale registration keeps the branch pinned.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-worktree-reclaim"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-bare.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q "$tmp/seed"
git -C "$tmp/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
mkdir -p "$tmp/cache"
git clone -q --bare "$tmp/seed" "$tmp/cache/demo.git"
mkdir -p "$tmp/worktrees"
git -C "$tmp/cache/demo.git" worktree add -q -b kanban/demo-card "$tmp/worktrees/demo-card" main 2>/dev/null \
  || git -C "$tmp/cache/demo.git" worktree add -q -b kanban/demo-card "$tmp/worktrees/demo-card" master
git -C "$tmp/cache/demo.git" worktree list --porcelain | grep -q "worktree $tmp/worktrees/demo-card\|/demo-card$"

export WORKTREES_DIR="$tmp/worktrees"
export LAST_STACK_RECLAIM_SKIP_BOARD=1 LAST_STACK_RECLAIM_SKIP_LSOF=1
export LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches"

# Dry run names the mirror, never the cache root.
out="$("$bin" --path "$tmp/worktrees/demo-card" --dry-run 2>&1)"
printf '%s\n' "$out" | grep -q "repo=$(cd "$tmp/cache/demo.git" && pwd -P)\|repo=$tmp/cache/demo.git" || {
  echo "FAIL: dry run must resolve repo to the bare mirror: $out" >&2; exit 1; }
if printf '%s\n' "$out" | grep -q "repo=$tmp/cache "; then
  echo "FAIL: resolved to the cache root: $out" >&2; exit 1
fi

# Real removal: the mirror forgets the worktree; nothing is an orphan rm.
out="$("$bin" --path "$tmp/worktrees/demo-card" 2>&1)"
if printf '%s\n' "$out" | grep -q 'rm orphan path'; then
  echo "FAIL: bare-mirror worktree removed as an orphan path: $out" >&2; exit 1
fi
[ ! -e "$tmp/worktrees/demo-card" ] || { echo "FAIL: worktree dir still present: $out" >&2; exit 1; }
if git -C "$tmp/cache/demo.git" worktree list --porcelain | grep -q 'demo-card'; then
  echo "FAIL: mirror still registers the removed worktree" >&2
  git -C "$tmp/cache/demo.git" worktree list --porcelain >&2
  exit 1
fi
[ -d "$tmp/cache/demo.git" ] || { echo "FAIL: the bare mirror itself was removed" >&2; exit 1; }

echo "ok last-stack-worktree-reclaim-bare-mirror"
