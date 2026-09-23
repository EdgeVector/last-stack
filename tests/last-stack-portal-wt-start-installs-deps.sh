#!/usr/bin/env bash
# Hermetic proof: a worktree with package.json + bun.lock gets its locked
# deps installed by `wt start` (fake bun here), and PORTAL_WT_NO_INSTALL=1
# skips that. (Stale-registration pruning is covered by
# tests/last-stack-portal-wt-stale-registration.sh from PR 120.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-deps.XXXXXX")"
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
branch="kanban/deps-proof"
dir_name="demo-kanban-deps-proof"

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

# Opt-out.
branch2="kanban/no-install-proof"
PORTAL_WT_NO_INSTALL=1 run_wt start "$branch2" >/dev/null 2>&1
test -d "$wt_root/demo-kanban-no-install-proof" || { echo "FAIL: no-install start" >&2; exit 1; }
test ! -e "$wt_root/demo-kanban-no-install-proof/node_modules" || {
  echo "FAIL: PORTAL_WT_NO_INSTALL=1 still installed" >&2; exit 1; }

echo "ok - wt start installs locked deps"
