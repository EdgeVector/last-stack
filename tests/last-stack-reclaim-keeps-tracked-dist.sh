#!/usr/bin/env bash
# strip_generated must not delete a "generated"-named directory that git TRACKS.
#
# Regression: fkanban, brain and situations all vendor an SDK as
# vendor/lastdb-app-sdk/dist and keep it tracked with a `!` un-ignore rule.
# The hourly disk-reclaim routine stripped those by NAME, leaving 100% of the
# affected worktrees (60/60 on 2026-08-02) permanently dirty with 32-40 tracked
# deletions — which the standing `git add -A` rule would then commit, removing
# build-critical vendored files.
#
# Uses --sweep-stale with a huge age gate: that strips build caches in every
# tree under WORKTREES_DIR but keeps the trees themselves ("keep young"), which
# exercises strip_generated without removing the fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="${LAST_STACK_RECLAIM_BIN:-$ROOT/bin/last-stack-worktree-reclaim}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/worktrees/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t

# Untracked build output that SHOULD be stripped.
mkdir -p "$repo/node_modules/pkg" "$repo/src/build"
echo junk > "$repo/node_modules/pkg/index.js"
echo junk > "$repo/src/build/out.o"

# Vendored prebuilt output that is tracked on purpose and must SURVIVE.
mkdir -p "$repo/vendor/sdk/dist"
echo 'module.exports={}' > "$repo/vendor/sdk/dist/index.js"
printf 'dist/\nnode_modules/\nbuild/\n!/vendor/sdk/dist/\n' > "$repo/.gitignore"
git -C "$repo" add -A
git -C "$repo" commit -qm init

# Sanity: the fixture is what the test claims it is.
[ -n "$(git -C "$repo" ls-files -- vendor/sdk/dist)" ] || {
  echo "fixture broken: vendor/sdk/dist is not tracked" >&2; exit 1; }

# HOME is overridden so the legacy ~/.kanban/worktrees root and the patch dir
# cannot reach the real machine.
#
# The free-space floor MUST be forced here. This test asserts that untracked
# build caches DO get stripped, but stripping is pressure-gated: with the
# default 80 GiB floor the assertion only holds on a host that happens to be
# below it. On a roomy machine the sweep logs `pressure_skip`, strips nothing,
# and the test failed for a reason that has nothing to do with tracked-dist
# handling. Pinning the floor absurdly high makes "under pressure" true
# everywhere, so this test measures what it claims to.
HOME="$tmp" WORKTREES_DIR="$tmp/worktrees" \
  LAST_STACK_RECLAIM_FREE_FLOOR_GIB=999999 \
  "$bin" --sweep-stale --max-age-hours 999999 >"$tmp/out.log" 2>&1 || true

if [ ! -f "$repo/vendor/sdk/dist/index.js" ]; then
  echo "FAIL: stripped a git-tracked dist/ directory" >&2
  sed -n '1,40p' "$tmp/out.log" >&2
  exit 1
fi

# The reclaim must still do its actual job on untracked output.
if [ -d "$repo/node_modules" ] || [ -d "$repo/src/build" ]; then
  echo "FAIL: untracked build caches were not stripped" >&2
  sed -n '1,40p' "$tmp/out.log" >&2
  exit 1
fi

# And it must not have left the tree dirty with tracked deletions.
if git -C "$repo" status --short | grep -q '^ D'; then
  echo "FAIL: reclaim left tracked deletions in the worktree" >&2
  git -C "$repo" status --short >&2
  exit 1
fi

echo "ok last-stack-reclaim-keeps-tracked-dist"
