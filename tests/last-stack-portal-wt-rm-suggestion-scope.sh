#!/usr/bin/env bash
# Hermetic proof: a failed `wt rm` never names an UNRELATED live worktree.
#
# The old fallback took its tokens from the NORMALIZED id. worktree_ids_from_spec
# rewrites a bare slug to `<SLUG>-kanban-<slug>`, so `kanban` — six characters,
# present in the basename of essentially every worktree this fleet creates — was
# always in the token list. Any same-portal sibling matched, and portal-wt
# printed `try: wt rm <that sibling>`: a destructive instruction aimed at another
# agent's checkout. Measured 2026-09-06 against a live tree holding uncommitted
# work (papercut-portal-wt-rm-suggests-deleting-an-unrelated-live-worktree-20260906).
#
# Pins three things:
#   1. a shared-`kanban` sibling is NOT suggested and NOT offered as `wt rm`
#   2. a genuine near-miss typo IS still suggested (the fallback still works)
#   3. a weak match never renders an executable `try: wt rm` line
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-rm-scope.XXXXXX")"
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
git -C "$cache" update-ref refs/heads/main refs/heads/main 2>/dev/null || true

printf 'demo\n' >"$portal/.portal/slug"
printf '%s\n' "$cache" >"$portal/.portal/remote"
printf 'lastgit\n' >"$portal/.portal/venue"
printf '%s\n' "$cache" >"$portal/.portal/cache"

run_wt() {
  WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

# The bystander: another agent's live worktree. Shares only `kanban`, which the
# normalizer inserts into every bare slug.
bystander="demo-kanban-unrelated-inner-loop-node-20260902"
run_wt start "unrelated-inner-loop-node-20260902" >/dev/null
test -d "$wt_root/$bystander" || {
  echo "FAIL: fixture bystander not created: $wt_root/$bystander" >&2
  exit 1
}

# --- 1. an already-gone slug must NOT name the bystander -------------------
set +e
out="$(run_wt rm "host-track-soak-must-not-starve-a-fast-merging-app-20260906" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: expected non-zero rm for a missing worktree" >&2; exit 1; }
if printf '%s\n' "$out" | grep -q "$bystander"; then
  echo "FAIL: rm of an unrelated slug named the bystander worktree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q 'try: wt rm'; then
  echo "FAIL: rm of an unrelated slug offered an executable removal command" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -qi 'already gone' || {
  echo "FAIL: a true miss with no related worktree must read 'already gone'" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
test -d "$wt_root/$bystander" || { echo "FAIL: bystander removed" >&2; exit 1; }

# --- 2. a real near-miss typo IS still surfaced ----------------------------
set +e
out2="$(run_wt rm "unrelated-inner-loop-node-20260902-typo" 2>&1)"
rc2=$?
set -e
[ "$rc2" -ne 0 ] || { echo "FAIL: expected non-zero rm for a near-miss typo" >&2; exit 1; }
printf '%s\n' "$out2" | grep -q "$bystander" || {
  echo "FAIL: a genuine near-miss must still name the worktree" >&2
  printf '%s\n' "$out2" >&2
  exit 1
}
printf '%s\n' "$out2" | grep -qi 'NOT cleaned' || {
  echo "FAIL: a live worktree must not read as cleaned up" >&2
  printf '%s\n' "$out2" >&2
  exit 1
}
test -d "$wt_root/$bystander" || { echo "FAIL: bystander removed by near-miss" >&2; exit 1; }

# --- 3. an AMBIGUOUS token names nothing -----------------------------------
# A token shared by two live worktrees is not evidence for either. Without the
# uniqueness rule the loop takes whichever the glob returns first, which is the
# same coin-flip that produced the original defect — just with a rarer token.
run_wt start "alpha-mutualtoken-20260902" >/dev/null
run_wt start "beta-mutualtoken-20260903" >/dev/null
test -d "$wt_root/demo-kanban-alpha-mutualtoken-20260902"
test -d "$wt_root/demo-kanban-beta-mutualtoken-20260903"
set +e
out3="$(run_wt rm "some-other-mutualtoken-thing-20260904" 2>&1)"
rc3=$?
set -e
[ "$rc3" -ne 0 ] || { echo "FAIL: expected non-zero rm for a missing worktree" >&2; exit 1; }
if printf '%s\n' "$out3" | grep -qE 'demo-kanban-(alpha|beta)-mutualtoken'; then
  echo "FAIL: an ambiguous token named one of two equally-matching worktrees" >&2
  printf '%s\n' "$out3" >&2
  exit 1
fi
printf '%s\n' "$out3" | grep -qi 'already gone' || {
  echo "FAIL: an ambiguous match must fall through to 'already gone'" >&2
  printf '%s\n' "$out3" >&2
  exit 1
}
run_wt rm "demo-kanban-alpha-mutualtoken-20260902" >/dev/null
run_wt rm "demo-kanban-beta-mutualtoken-20260903" >/dev/null

# --- 4. the exact id still removes ----------------------------------------
run_wt rm "$bystander" >/dev/null
if [ -e "$wt_root/$bystander" ]; then
  echo "FAIL: exact-id rm did not remove the worktree" >&2
  exit 1
fi

echo "PASS last-stack-portal-wt-rm-suggestion-scope"
