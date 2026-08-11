#!/usr/bin/env bash
# Regression: a clean idle worktree registered outside WORKTREES_DIR must not
# pin the portal mirror's main ref. Dirty worktrees remain fail-closed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-fetch-main-pin.XXXXXX")"
portal="$WORK/portal"
source_repo="$WORK/source"
remote="$WORK/remote.git"
cache="$WORK/cache.git"
wt_root="$WORK/managed-worktrees"
stray="$WORK/outside-managed-root/stray-main"

cleanup() {
  if [ -d "$cache" ]; then
    git -C "$cache" worktree remove --force "$stray" 2>/dev/null || true
    git -C "$cache" worktree prune 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$portal/.portal" "$source_repo" "$wt_root" "$(dirname "$stray")"
git -C "$source_repo" init -q -b main
printf 'seed\n' >"$source_repo/README"
git -C "$source_repo" add README
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m seed
git clone -q --bare "$source_repo" "$remote"
git clone -q --bare "$remote" "$cache"
git -C "$cache" config remote.origin.fetch "+refs/heads/*:refs/heads/*"

printf 'demo\n' >"$portal/.portal/slug"
printf '%s\n' "$remote" >"$portal/.portal/remote"
printf 'lastgit\n' >"$portal/.portal/venue"
printf '%s\n' "$cache" >"$portal/.portal/cache"

run_wt() {
  WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

# Reproduce the fleet-wide pin: the registered worktree is deliberately outside
# the managed root and has main checked out directly.
git -C "$cache" worktree add --quiet "$stray" main
printf 'remote-two\n' >>"$source_repo/README"
git -C "$source_repo" add README
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m remote-two
git -C "$source_repo" push -q "$remote" main

fetch_out="$(run_wt fetch 2>&1)"
printf '%s\n' "$fetch_out" | grep -q 'auto-detached clean idle worktree pinning main'
[ -z "$(git -C "$stray" branch --show-current)" ] || {
  echo "expected stray worktree to be detached" >&2
  exit 1
}
[ "$(git -C "$cache" rev-parse refs/heads/main)" = "$(git -C "$source_repo" rev-parse HEAD)" ] || {
  echo "expected portal cache main to advance after self-heal" >&2
  exit 1
}

# Negative case: dirty work is never detached or overwritten. Fetch remains
# blocked and reports the unsafe pin.
git -C "$stray" checkout -q main
printf 'local-only\n' >>"$stray/README"
printf 'remote-three\n' >>"$source_repo/README"
git -C "$source_repo" add README
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m remote-three
git -C "$source_repo" push -q "$remote" main

set +e
dirty_out="$(run_wt fetch 2>&1)"
dirty_rc=$?
set -e
[ "$dirty_rc" -ne 0 ] || {
  echo "expected dirty main pin to keep fetch fail-closed" >&2
  exit 1
}
printf '%s\n' "$dirty_out" | grep -q 'refusing to detach dirty worktree pinning main'
[ "$(git -C "$stray" branch --show-current)" = main ] || {
  echo "dirty worktree must remain on main" >&2
  exit 1
}
grep -q 'local-only' "$stray/README"

echo "PASS last-stack-portal-wt-fetch-detaches-idle-main"
