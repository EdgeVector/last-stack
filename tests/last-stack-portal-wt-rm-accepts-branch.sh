#!/usr/bin/env bash
# Hermetic proof: wt start <branch> then wt rm <same-branch> removes the
# worktree. Also: wrong id with a near match suggests basename and exits
# non-zero while the worktree remains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-rm-branch.XXXXXX")"
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
branch="kanban/portal-wt-rm-accepts-branch-proof"
dir_name="demo-kanban-portal-wt-rm-accepts-branch-proof"

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

# --- start with branch ---
out="$(run_wt start "$branch" 2>&1)"
printf '%s\n' "$out" | grep -q "branch  $branch"
printf '%s\n' "$out" | grep -q "path    $wt_root/$dir_name"
test -d "$wt_root/$dir_name" || {
  echo "expected worktree dir after start: $wt_root/$dir_name" >&2
  exit 1
}

# --- red-before shape: wrong string that is a near-miss must fail + leave wt ---
set +e
miss_out="$(run_wt rm "kanban/portal-wt-rm-accepts-branch-PROOF-typo" 2>&1)"
miss_rc=$?
set -e
[ "$miss_rc" -ne 0 ] || {
  echo "expected non-zero rm for near-miss typo" >&2
  exit 1
}
printf '%s\n' "$miss_out" | grep -qi 'not removed\|likely basename\|NOT cleaned'
test -d "$wt_root/$dir_name" || {
  echo "near-miss rm must leave worktree on disk" >&2
  exit 1
}

# --- green: rm with the SAME branch start accepted ---
rm_out="$(run_wt rm "$branch" 2>&1)"
printf '%s\n' "$rm_out" | grep -q "removed $wt_root/$dir_name"
if [ -e "$wt_root/$dir_name" ]; then
  echo "worktree still present after rm by branch" >&2
  exit 1
fi

# --- start again; rm by bare slug (no kanban/ prefix) ---
run_wt start "portal-wt-rm-accepts-branch-proof" >/dev/null
test -d "$wt_root/$dir_name"
run_wt rm "portal-wt-rm-accepts-branch-proof" >/dev/null
if [ -e "$wt_root/$dir_name" ]; then
  echo "worktree still present after rm by bare slug" >&2
  exit 1
fi

# --- start again; rm by dir basename ---
run_wt start "$branch" >/dev/null
test -d "$wt_root/$dir_name"
run_wt rm "$dir_name" >/dev/null
if [ -e "$wt_root/$dir_name" ]; then
  echo "worktree still present after rm by dir basename" >&2
  exit 1
fi

# --- true miss (already gone): discriminating already-gone wording ---
set +e
gone_out="$(run_wt rm "$branch" 2>&1)"
gone_rc=$?
set -e
[ "$gone_rc" -ne 0 ] || {
  echo "expected non-zero when already gone" >&2
  exit 1
}
printf '%s\n' "$gone_out" | grep -qi 'already gone'

echo "PASS last-stack-portal-wt-rm-accepts-branch"
