#!/usr/bin/env bash
# Hermetic proof: a worktree whose directory was deleted without `git
# worktree remove` does not block `wt start` of the same branch, and `wt list`
# stops showing it. papercut-portal-wt-stale-missing-registration-blocks-recreate-20260922,
# papercut-fold-portal-worktree-list-stale-paths-20260920.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-stale-reg.XXXXXX")"
cleanup() {
  # Detach any git worktrees we attached under WORK before rm -rf.
  if [ -d "$WORK/cache.git" ]; then
    git -C "$WORK/cache.git" worktree prune 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

portal="$WORK/portal"
source_repo="$WORK/source"
cache="$WORK/cache.git"
wt_root="$WORK/worktrees"
branch="kanban/portal-wt-stale-registration-proof"
dir_name="demo-kanban-portal-wt-stale-registration-proof"

mkdir -p "$portal/.portal" "$source_repo" "$wt_root"
git -C "$source_repo" init -q -b main
printf 'seed\n' >"$source_repo/README"
git -C "$source_repo" add README
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m 'seed'
git clone -q --bare "$source_repo" "$cache"
# Make origin fetchable by name (portal-wt fetch uses origin).
git -C "$cache" remote remove origin 2>/dev/null || true
git -C "$cache" remote add origin "$cache"
git -C "$cache" config remote.origin.fetch "+refs/heads/*:refs/heads/*"
# Seed main ref as heads/main for ensure_cache.
git -C "$cache" update-ref refs/heads/main refs/heads/main 2>/dev/null || true

printf 'demo\n' >"$portal/.portal/slug"
printf '%s\n' "$cache" >"$portal/.portal/remote"
printf 'lastgit\n' >"$portal/.portal/venue"
printf '%s\n' "$cache" >"$portal/.portal/cache"

run_wt() {
  WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

# Start, then delete the directory behind git's back (as disk-reclaim did).
run_wt start "$branch" >/dev/null 2>&1
test -d "$wt_root/$dir_name"
rm -rf "$wt_root/$dir_name"
git -C "$cache" worktree list --porcelain | grep -q "/$dir_name$" || {
  echo "fixture: expected a stale registration" >&2; exit 1; }

# wt list prunes it and no longer shows the dead path.
list_out="$(run_wt list 2>&1)"
if printf '%s\n' "$list_out" | grep -q "/$dir_name"; then
  echo "wt list still shows the missing worktree:" >&2
  printf '%s\n' "$list_out" >&2
  exit 1
fi
printf '%s\n' "$list_out" | grep -q "pruned 1 stale worktree registration"

# Recreate the stale registration, then wt start must succeed directly.
run_wt start "$branch" >/dev/null 2>&1
rm -rf "$wt_root/$dir_name"
out="$(run_wt start "$branch" 2>&1)" || {
  echo "wt start refused a branch held only by a missing worktree:" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
test -d "$wt_root/$dir_name"
echo "ok: stale worktree registrations do not block start or clutter list"
