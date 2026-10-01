#!/usr/bin/env bash
# A clean working tree can still hold commits that exist nowhere else, when the
# branch advanced locally after its PR was pushed. save_patch returns early on a
# clean tree, so before this cover those commits were removed with no salvage.
#
# papercut-loom-worktree-reclaim-reaps-a-clean-tree-holding-unpushed-commits-20261001:
# 3 commits were lost on 2026-10-01 while the PR had already merged the stale
# origin head, so nothing upstream held them either.
#
# The salvage must NOT refuse the reap: the pool still has to shrink, per
# papercut-loom-step-worktrees-never-removed-at-terminal-20260925. Every case
# below therefore asserts the tree was removed as well.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-loom-worktree-reclaim"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/loom-reclaim-unpushed.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

wts="$tmp/worktrees"; mkdir -p "$wts"
git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
g "$tmp/repo" commit -q --allow-empty -m init
g "$tmp/repo" branch -M main
g "$tmp/repo" push -q origin main

old() { touch -t 202001010000 "$1"; }

# A branch worktree that origin knows about, then N more local commits on top.
mk_branch() { # <name> <pushed-commits> <extra-local-commits>
  # Split: bash expands every argument to `local` BEFORE assigning any of them,
  # so a later assignment cannot reference an earlier one in the same statement.
  local name="$1" pushed="$2" extra="$3" i
  local wt="$wts/$name#IMPLEMENT"
  g "$tmp/repo" branch "$name" main
  g "$tmp/repo" worktree add -q "$wt" "$name"
  # C-style loops, NOT `for i in $(seq 1 $n)`: BSD seq counts DOWN on an empty
  # range, so `seq 1 0` emits "1 0" on macOS and the zero-iteration case silently
  # runs twice. That made the fully-pushed fixture carry 2 unintended commits.
  for ((i = 1; i <= pushed; i++)); do
    echo "pushed $i" >"$wt/p$i.txt"; g "$wt" add -A; g "$wt" commit -q -m "pushed $i"
  done
  if [ "$pushed" -gt 0 ]; then g "$wt" push -q origin "$name"; fi
  for ((i = 1; i <= extra; i++)); do
    echo "local $i" >"$wt/l$i.txt"; g "$wt" add -A; g "$wt" commit -q -m "LOCAL ONLY $i"
  done
  # The fixture is only a fixture if it is the shape it claims.
  if [ "$extra" -eq 0 ] && [ -n "$(g "$wt" rev-list "refs/remotes/origin/$name..HEAD" 2>/dev/null)" ]; then
    fail "fixture $name claims 0 unpushed commits but has some"
  fi
  : >"$wt.loom-guard"; old "$wt"
}

mk_detached() { # <name>
  local wt="$wts/$1#IMPLEMENT"
  g "$tmp/repo" worktree add -q --detach "$wt" main
  echo x >"$wt/d.txt"; g "$wt" add -A; g "$wt" commit -q -m "detached commit"
  : >"$wt.loom-guard"; old "$wt"
}

mk_branch lx-unpushed-clean 1 2      # the defect: clean tree, 2 local-only commits
mk_branch lx-fully-pushed   2 0      # nothing to salvage
mk_branch lx-never-pushed   0 1      # no origin/<branch> at all -> base is origin/main
mk_branch lx-dirty-unpushed 1 1      # both salvage paths must fire
echo wip >"$wts/lx-dirty-unpushed#IMPLEMENT/wip.txt"
old "$wts/lx-dirty-unpushed#IMPLEMENT"   # re-age: writing the file refreshed the mtime
mk_detached lx-detached              # no branch: must not crash, nothing to bundle

stub="$tmp/stub"; mkdir -p "$stub"
printf '%s\n' '#!/usr/bin/env bash' 'echo "status: succeeded"' >"$stub/loom"
printf '%s\n' '#!/usr/bin/env bash' "printf 'p1\\nn/\\n'" >"$stub/lsof"
chmod +x "$stub/loom" "$stub/lsof"

run() {
  LOOM_WORKTREES_DIR="$wts" LOOM_BIN="$stub/loom" \
    LAST_STACK_LOOM_RECLAIM_LSOF="$stub/lsof" \
    LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches" "$bin" "$@"
}

bundle_for() { ls "$tmp/patches"/loom-"$1"_IMPLEMENT-*.bundle 2>/dev/null | head -1; }
patch_for()  { ls "$tmp/patches"/loom-"$1"_IMPLEMENT-*.patch  2>/dev/null | head -1; }

# --- dry run salvages nothing and removes nothing -----------------------------
out="$(run --dry-run)"
echo "$out" | grep -q 'dry-run would save 2 unpushed commit(s)' \
  || fail "dry-run should name the unpushed count: $out"
[ -z "$(bundle_for lx-unpushed-clean)" ] || fail "dry-run must not write a bundle"
[ -d "$wts/lx-unpushed-clean#IMPLEMENT" ] || fail "dry-run must not remove the tree"

# --- the real sweep -----------------------------------------------------------
out="$(run)"

# 1. clean tree, local-only commits: bundled, and the tree is still reclaimed.
b="$(bundle_for lx-unpushed-clean)"
[ -n "$b" ] || fail "no bundle for a clean tree holding unpushed commits"
[ ! -e "$wts/lx-unpushed-clean#IMPLEMENT" ] || fail "salvage must not refuse the reap"
# `bundle verify` checks the prerequisites are present, so it has to run inside a
# repo that already has the base commit -- not standalone.
g "$tmp/repo" bundle verify "$b" >/dev/null 2>&1 || fail "bundle does not verify: $b"
# The salvage is only real if the commits come BACK out of it. Assertions here
# redirect to a file and grep the FILE: under `set -o pipefail`, `cmd | grep -q`
# can report failure precisely BECAUSE it matched, since grep -q exits early and
# the producer dies on SIGPIPE.
g "$tmp/repo" fetch -q "$b" 'refs/heads/*:refs/heads/salvaged/*' 2>"$tmp/fetch.err" \
  || fail "cannot fetch from the salvage bundle: $(cat "$tmp/fetch.err")"
g "$tmp/repo" log --format=%s refs/heads/salvaged/lx-unpushed-clean >"$tmp/salvaged.log" 2>&1 \
  || fail "no salvaged ref after fetch. bundle heads: $(g "$tmp/repo" bundle list-heads "$b" 2>&1 | tr '\n' ' ')"
grep -q 'LOCAL ONLY 2' "$tmp/salvaged.log" \
  || fail "the lost commit is not in the bundle. got: $(tr '\n' ' ' <"$tmp/salvaged.log")"
[ "$(g "$tmp/repo" rev-list --count refs/remotes/origin/lx-unpushed-clean..refs/heads/salvaged/lx-unpushed-clean)" = 2 ] \
  || fail "bundle should carry exactly the 2 local-only commits"

# 2. fully pushed: nothing to save, so no bundle at all.
#
# The absent-bundle assertion alone is NOT a guard: with the count check removed,
# `git bundle create` fails on an empty range by itself and still writes nothing,
# so that assertion stays green through the defect. The load-bearing assertion is
# that the sweep says NOTHING about this tree -- no save line and no WARNING --
# because reaching `bundle create` at all is what logs the WARNING.
printf '%s' "$out" >"$tmp/sweep.log"
[ -z "$(bundle_for lx-fully-pushed)" ] \
  || fail "fully-pushed tree must not produce a bundle; log said: $(grep -i 'lx-fully-pushed' "$tmp/sweep.log" | tr '\n' ' ')"
grep 'lx-fully-pushed' "$tmp/sweep.log" | grep -qE 'unpushed commit|WARNING' \
  && fail "fully-pushed tree must not reach the salvage path: $(grep -i 'lx-fully-pushed' "$tmp/sweep.log" | tr '\n' ' ')"
[ ! -e "$wts/lx-fully-pushed#IMPLEMENT" ] || fail "lx-fully-pushed should be removed"

# 3. never pushed: no origin/<branch>, so the range falls back to origin/main.
[ -n "$(bundle_for lx-never-pushed)" ] || fail "a never-pushed branch must still be bundled"
echo "$out" | grep -q 'vs refs/remotes/origin/main' \
  || fail "fallback base should be named in the log: $out"

# 4. dirty AND unpushed: both salvage paths fire; neither suppresses the other.
[ -n "$(patch_for lx-dirty-unpushed)" ]  || fail "dirty patch missing"
[ -n "$(bundle_for lx-dirty-unpushed)" ] || fail "unpushed bundle missing alongside the patch"

# 5. detached HEAD: no branch to compare, no bundle, no crash, still reclaimed.
[ -z "$(bundle_for lx-detached)" ] || fail "detached HEAD must not produce a bundle"
[ ! -e "$wts/lx-detached#IMPLEMENT" ] || fail "lx-detached should be removed"

echo "ok last-stack-loom-reclaim-salvages-unpushed-commits"
