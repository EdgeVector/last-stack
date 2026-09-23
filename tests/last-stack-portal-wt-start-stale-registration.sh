#!/usr/bin/env bash
# Hermetic proof for two `wt start` repairs:
# 1. A worktree whose directory was removed without `git worktree prune`
#    stays registered in the mirror. `wt start` for the same branch must
#    prune that stale entry and recreate the worktree, not fail with
#    "missing but already registered worktree".
# 2. A worktree with package.json + bun.lock gets its locked deps installed
#    (fake bun here), and PORTAL_WT_NO_INSTALL=1 skips that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-stale-reg.XXXXXX")"
cleanup() {
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
fakebin="$WORK/fakebin"
branch="kanban/stale-registration-proof"
dir_name="demo-kanban-stale-registration-proof"

mkdir -p "$portal/.portal" "$source_repo" "$wt_root" "$fakebin"
git -C "$source_repo" init -q -b main
printf '{"name":"demo"}\n' >"$source_repo/package.json"
printf '{}\n' >"$source_repo/bun.lock"
git -C "$source_repo" add package.json bun.lock
git -C "$source_repo" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m 'seed'
git clone -q --bare "$source_repo" "$cache"
git -C "$cache" remote remove origin 2>/dev/null || true
git -C "$cache" remote add origin "$cache"
git -C "$cache" config remote.origin.fetch "+refs/heads/*:refs/heads/*"

printf 'demo\n' >"$portal/.portal/slug"
printf '%s\n' "$cache" >"$portal/.portal/remote"
printf 'forgejo\n' >"$portal/.portal/venue"
printf '%s\n' "$cache" >"$portal/.portal/cache"

# Fake bun: `bun install --frozen-lockfile` creates node_modules/.fake-bun.
cat >"$fakebin/bun" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = install ] || exit 3
mkdir -p node_modules && : >node_modules/.fake-bun
SH
chmod +x "$fakebin/bun"

run_wt() {
  PATH="$fakebin:$PATH" WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

run_wt start "$branch" >/dev/null 2>&1
test -d "$wt_root/$dir_name" || { echo "FAIL: first start made no worktree" >&2; exit 1; }
test -f "$wt_root/$dir_name/node_modules/.fake-bun" || {
  echo "FAIL: start did not install locked deps" >&2; exit 1; }

# Remove the directory the way a reclaim or a hand rm does: no prune.
rm -rf "$wt_root/$dir_name"
real_wt_root="$(cd "$wt_root" && pwd -P)"
git -C "$cache" worktree list --porcelain \
  | grep -Fx -e "worktree $wt_root/$dir_name" -e "worktree $real_wt_root/$dir_name" >/dev/null || {
  echo "FAIL: fixture expected a stale registration" >&2; exit 1; }

set +e
out="$(run_wt start "$branch" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: restart rc=$rc: $out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'registered but missing' || {
  echo "FAIL: restart did not say it pruned: $out" >&2; exit 1; }
test -d "$wt_root/$dir_name" || { echo "FAIL: restart made no worktree" >&2; exit 1; }

# Opt-out.
branch2="kanban/no-install-proof"
PORTAL_WT_NO_INSTALL=1 run_wt start "$branch2" >/dev/null 2>&1
test -d "$wt_root/demo-kanban-no-install-proof" || { echo "FAIL: no-install start" >&2; exit 1; }
test ! -e "$wt_root/demo-kanban-no-install-proof/node_modules" || {
  echo "FAIL: PORTAL_WT_NO_INSTALL=1 still installed" >&2; exit 1; }

echo "ok - wt start prunes a stale registration and installs locked deps"
