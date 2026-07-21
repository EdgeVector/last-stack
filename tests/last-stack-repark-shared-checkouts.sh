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

git -C "$repo" init --quiet -b main
git -C "$repo" config user.name "Last Stack Test"
git -C "$repo" config user.email "last-stack-test@example.invalid"
printf 'ok\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit --quiet -m "init"
git -C "$tmp" init --quiet --bare origin.git
git -C "$repo" remote add origin "$tmp/origin.git"
git -C "$repo" push --quiet -u origin main

out="$(REPARK_WORKSPACE="$ws" "$ROOT/bin/last-stack-repark-shared-checkouts" --dry-run)"
case "$out" in
  *"FLAG example"*"repo-local .worktrees present"*"~/.fkanban/worktrees"*) ;;
  *)
    printf '%s\n' "$out" >&2
    echo "expected repo-local .worktrees guard in repark output" >&2
    exit 1
    ;;
esac

collision_repo="$ws/collision"
mkdir -p "$collision_repo/routines"
git -C "$collision_repo" init --quiet -b main
git -C "$collision_repo" config user.name "Last Stack Test"
git -C "$collision_repo" config user.email "last-stack-test@example.invalid"
printf 'base\n' > "$collision_repo/README.md"
git -C "$collision_repo" add README.md
git -C "$collision_repo" commit --quiet -m "init"
git -C "$tmp" init --quiet --bare collision-origin.git
git -C "$collision_repo" remote add origin "$tmp/collision-origin.git"
git -C "$collision_repo" push --quiet -u origin main

date_slug="$(date +%Y%m%d)"
git -C "$collision_repo" switch --quiet -c "salvage/shared-checkout-$date_slug"
printf 'old salvage\n' > "$collision_repo/routines/program-driver.md"
git -C "$collision_repo" add routines/program-driver.md
git -C "$collision_repo" commit --quiet -m "old salvage"
git -C "$collision_repo" switch --quiet main
mkdir -p "$collision_repo/routines"
printf 'new local work\n' > "$collision_repo/routines/program-driver.md"
touch -t 202001010000 "$collision_repo/routines/program-driver.md"
touch -t 202001010000 "$collision_repo/routines"

out="$(REPARK_WORKSPACE="$ws" "$ROOT/bin/last-stack-repark-shared-checkouts")"
case "$out" in
  *"cannot open salvage branch"*)
    printf '%s\n' "$out" >&2
    echo "expected colliding salvage branch to fall back to a unique branch" >&2
    exit 1
    ;;
esac
case "$out" in
  *"ok   collision"*"salvaged-on:salvage/shared-checkout-$date_slug-1"*) ;;
  *)
    printf '%s\n' "$out" >&2
    echo "expected collision repo to salvage onto unique branch" >&2
    exit 1
    ;;
esac
git -C "$collision_repo" rev-parse --verify -q "refs/heads/salvage/shared-checkout-$date_slug-1" >/dev/null

echo "ok last-stack-repark-shared-checkouts"
