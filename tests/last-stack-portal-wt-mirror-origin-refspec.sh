#!/usr/bin/env bash
# Regression: a portal bare mirror must fetch remote branches into
# refs/remotes/origin/*, so `git fetch origin` from a worktree is never refused
# by a sibling worktree's branch and never leaves origin/<main> silently stale.
#
# Both broken shapes existed on this fleet (36 mirrors, 8 collision + 28 unset)
# and both exit 0 while freezing the ref the caller is about to trust:
#   +refs/heads/*:refs/heads/*  -> fetch refuses on a checked-out branch
#   (unset)                     -> fetch writes FETCH_HEAD only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-wt"
WANT_REFSPEC='+refs/heads/*:refs/remotes/origin/*'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portal-wt-mirror-refspec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

commit_to_source() {
  local repo="$1" msg="$2"
  printf '%s\n' "$msg" >>"$repo/README"
  git -C "$repo" add README
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid \
    commit -q -m "$msg"
}

# Build a portal + bare mirror whose remote.origin.fetch is $1 ("" = unset).
setup_case() {
  local case_name="$1" refspec="$2"
  source_repo="$WORK/$case_name-source"
  remote="$WORK/$case_name-remote.git"
  cache="$WORK/$case_name-cache.git"
  portal="$WORK/$case_name-portal"
  wt_root="$WORK/$case_name-worktrees"

  mkdir -p "$source_repo" "$wt_root" "$portal/.portal"
  git -C "$source_repo" init -q -b main
  commit_to_source "$source_repo" seed
  git clone -q --bare "$source_repo" "$remote"
  git clone -q --bare "$remote" "$cache"
  git -C "$cache" config --unset-all remote.origin.fetch 2>/dev/null || true
  [ -z "$refspec" ] || git -C "$cache" config remote.origin.fetch "$refspec"

  printf '%s\n' "$case_name" >"$portal/.portal/slug"
  printf '%s\n' "$remote" >"$portal/.portal/remote"
  printf 'lastgit\n' >"$portal/.portal/venue"
  printf '%s\n' "$cache" >"$portal/.portal/cache"
}

run_wt() {
  WORKTREES_DIR="$wt_root" EDGEVECTOR_GIT_CACHE="$WORK" \
    bash "$BIN" --portal "$portal" "$@"
}

advance_remote() {
  commit_to_source "$source_repo" "$1"
  git -C "$source_repo" push -q "$remote" main
  git -C "$remote" rev-parse refs/heads/main
}

# --- Case A: mirror with NO fetch refspec (the shape that answers stale) ---
setup_case unset ""
run_wt start feat-a >/dev/null 2>&1
wt_a="$wt_root/unset-kanban-feat-a"
[ -d "$wt_a" ] || fail "case A worktree not created at $wt_a"

got="$(git -C "$cache" config --get remote.origin.fetch 2>/dev/null || true)"
[ "$got" = "$WANT_REFSPEC" ] \
  || fail "case A refspec not healed: got [$got] want [$WANT_REFSPEC]"

tip="$(advance_remote second)"
run_wt fetch >/dev/null 2>&1
[ "$(git -C "$cache" rev-parse refs/remotes/origin/main)" = "$tip" ] \
  || fail "case A origin/main stale after wt fetch"
[ "$(git -C "$cache" rev-parse refs/heads/main)" = "$tip" ] \
  || fail "case A mirror refs/heads/main stale after wt fetch"

# The core defect: a plain `git fetch origin` from the worktree must move
# origin/main. Before the fix this exited 0 and wrote FETCH_HEAD only, so every
# later `merge-base --is-ancestor <oid> origin/main` answered from clone time.
tip="$(advance_remote third)"
git -C "$wt_a" fetch -q origin || fail "case A plain fetch failed"
[ "$(git -C "$wt_a" rev-parse origin/main)" = "$tip" ] \
  || fail "case A worktree origin/main stale after plain 'git fetch origin'"

# --- Case B: legacy collision refspec + a sibling worktree on a branch ---
setup_case collision '+refs/heads/*:refs/heads/*'
run_wt start sibling >/dev/null 2>&1
wt_sib="$wt_root/collision-kanban-sibling"
[ -d "$wt_sib" ] || fail "case B sibling worktree not created"

got="$(git -C "$cache" config --get remote.origin.fetch 2>/dev/null || true)"
[ "$got" = "$WANT_REFSPEC" ] \
  || fail "case B refspec not healed: got [$got] want [$WANT_REFSPEC]"

# With the collision refspec this fetch aborted rc=128 ("refusing to fetch into
# branch ... checked out at ...") and froze every ref, including main.
tip="$(advance_remote second)"
git -C "$wt_sib" fetch -q origin \
  || fail "case B plain fetch refused while a sibling branch is checked out"
[ "$(git -C "$wt_sib" rev-parse origin/main)" = "$tip" ] \
  || fail "case B origin/main stale after plain 'git fetch origin'"
[ "$(git -C "$wt_sib" rev-parse --abbrev-ref HEAD)" = "kanban/sibling" ] \
  || fail "case B fetch moved the checked-out branch"

# --- Case C: refs/heads/<main> pinned by a worktree portal-wt cannot inspect ---
# A registered worktree whose directory was deleted still pins refs/heads/main,
# and `git status` inside it fails, so the auto-detach cannot clear it and the
# dirty-pin fail-closed does not apply. The branch fetch is refused, main stays
# stale, and before this fix `wt start` silently based new work on that stale
# tip. origin/<main> is the one ref no worktree can pin, so it must be both
# reported and used as the base.
stray="$WORK/collision-stray-main"
git -C "$cache" worktree add --quiet "$stray" main
pinned="$(git -C "$cache" rev-parse refs/heads/main)"
rm -rf "$stray"
git -C "$stray" status --short >/dev/null 2>&1 \
  && fail "case C fixture: removed worktree must not be inspectable"

tip="$(advance_remote third)"
[ "$tip" != "$pinned" ] || fail "case C fixture: remote did not advance"

warn="$(run_wt start later 2>&1 >/dev/null || true)"
printf '%s\n' "$warn" | grep -q "WARNING refs/heads/main is stale" \
  || fail "case C did not warn that the mirror branch ref is stale: $warn"
[ "$(git -C "$cache" rev-parse refs/heads/main)" = "$pinned" ] \
  || fail "case C fixture: refs/heads/main was expected to stay pinned"
[ "$(git -C "$cache" rev-parse refs/remotes/origin/main)" = "$tip" ] \
  || fail "case C origin/main stale while refs/heads/main is pinned"

wt_later="$wt_root/collision-kanban-later"
[ -d "$wt_later" ] || fail "case C worktree not created"
[ "$(git -C "$wt_later" rev-parse HEAD)" = "$tip" ] \
  || fail "case C new worktree based on the pinned stale tip, not the remote tip"

git -C "$cache" worktree prune

echo "PASS last-stack-portal-wt-mirror-origin-refspec"
