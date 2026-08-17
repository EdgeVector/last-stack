#!/usr/bin/env bash
# `wt start --help` must print usage and must not create a worktree named
# kanban/--help (papercut-portal-wt-start-help-creates-a-worktree).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-start-help.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

portal="$WORK/portal"
source_repo="$WORK/source"
cache="$WORK/cache.git"
wt_root="$WORK/worktrees"

mkdir -p "$portal/.portal" "$source_repo" "$wt_root"
git -C "$source_repo" init -q -b main
printf 'seed\n' >"$source_repo/README"
git -C "$source_repo" add README
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m 'seed'
git clone -q --bare "$source_repo" "$cache"
git -C "$cache" remote remove origin 2>/dev/null || true
git -C "$cache" remote add origin "$cache"
git -C "$cache" config remote.origin.fetch "+refs/heads/*:refs/heads/*"

printf 'demo\n' >"$portal/.portal/slug"
printf '%s\n' "$cache" >"$portal/.portal/remote"
printf 'lastgit\n' >"$portal/.portal/venue"
printf '%s\n' "$cache" >"$portal/.portal/cache"

run_wt() {
  WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

out="$(run_wt start --help)"
printf '%s\n' "$out" | grep -q 'usage: wt start'
if find "$wt_root" -mindepth 1 -maxdepth 1 | grep -q .; then
  echo "FAIL: start --help created a worktree under $wt_root" >&2
  find "$wt_root" -mindepth 1 >&2
  exit 1
fi

out_h="$(run_wt start -h)"
printf '%s\n' "$out_h" | grep -q 'usage: wt start'

echo "ok last-stack-portal-wt-start-help"
