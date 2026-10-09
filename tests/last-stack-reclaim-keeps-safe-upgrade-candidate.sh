#!/usr/bin/env bash
# Regression cover for papercut-worktree-reclaim-strips-safe-upgrade-candidate-
# before-fresh-grace-20261008.
#
# On 2026-10-08 the hourly disk reclaim ran under disk pressure and stripped the
# target/ of a worktree that held a validated LastDB safe-upgrade candidate pair.
# The strip ran before the fresh-age grace and before any protection, so the
# CUTOVER failed with "No such file or directory" between PROBE and CUTOVER.
#
#   1. a fresh worktree is not stripped (the grace used to guard removal only)
#   2. a worktree that holds a reserved candidate is not stripped or removed
#   3. an expired reservation protects nothing
#   4. the control cases still strip and remove, so 1-3 can fail
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${LAST_STACK_RECLAIM_BIN:-$ROOT/bin/last-stack-worktree-reclaim}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

WT="$tmp/worktrees"
RESERVE="$tmp/reservations"
mkdir -p "$WT" "$RESERVE"
: >"$tmp/open-heads.tsv"
export LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$tmp/open-heads.tsv"

# mk_wt <name> <dirty|clean> <aged|fresh>
# Every tree carries target/release/lastdbd, the shape of a candidate pair.
mk_wt() {
  local name kind age d
  name="$1"
  kind="$2"
  age="$3"
  d="$WT/$name"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@e.com
  git -C "$d" config user.name t
  printf 'target/\n' >"$d/.gitignore"
  echo hi >"$d/f.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  mkdir -p "$d/target/release"
  echo binary >"$d/target/release/lastdbd"
  if [ "$kind" = "dirty" ]; then
    echo scratch >"$d/untracked.txt"
  fi
  if [ "$age" = "aged" ]; then
    touch -t 202001010000 "$d"
  else
    touch "$d"
  fi
}

# reserve <name> <expiry-epoch> <path>
reserve() {
  printf '%s\t%s\n' "$2" "$3" >"$RESERVE/$1.reserve"
}

now="$(date -u +%s)"
future=$((now + 3600))
past=$((now - 3600))

mk_wt ctrl-dirty dirty aged
mk_wt ctrl-clean clean aged
mk_wt fresh-dirty dirty fresh
mk_wt res-dirty dirty aged
mk_wt res-clean clean aged
mk_wt exp-dirty dirty aged

reserve res-dirty "$future" "$WT/res-dirty/target/release/lastdbd"
reserve res-clean "$future" "$WT/res-clean/target/release/lastdbd"
reserve exp-dirty "$past" "$WT/exp-dirty/target/release/lastdbd"

# FREE_FLOOR far above any real free space forces the disk-pressure strip path.
out="$(HOME="$tmp" WORKTREES_DIR="$WT" \
  LAST_STACK_RECLAIM_RESERVE_DIR="$RESERVE" \
  LAST_STACK_RECLAIM_FREE_FLOOR_GIB=999999999 \
  LAST_STACK_RECLAIM_SKIP_BOARD=1 LAST_STACK_RECLAIM_SKIP_LSOF=1 \
  "$bin" --sweep-stale --max-age-hours 999999 2>&1 || true)"

fail() {
  echo "FAIL: $1" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

printf '%s' "$out" | grep -q 'strip_enabled=1' \
  || fail "the disk-pressure strip path was not reached, so no case below proves anything"

# 4. controls: the unprotected aged trees are stripped / removed.
[ ! -e "$WT/ctrl-dirty/target" ] \
  || fail "control: an aged, unreserved dirty tree kept its target/ (the strip no longer runs)"
[ -e "$WT/ctrl-dirty/f.txt" ] \
  || fail "control: a dirty tree was removed instead of only stripped"
[ ! -e "$WT/ctrl-clean" ] \
  || fail "control: an aged, clean, unreserved tree was not reclaimed"

# 1. fresh grace guards the strip.
[ -e "$WT/fresh-dirty/target/release/lastdbd" ] \
  || fail "a worktree inside the fresh grace had its target/ stripped"
printf '%s' "$out" | grep -q 'keep strip-skip reason=fresh .*fresh-dirty' \
  || fail "the fresh skip was not logged for fresh-dirty"

# 2. a reserved candidate survives both the strip and the removal.
[ -e "$WT/res-dirty/target/release/lastdbd" ] \
  || fail "a reserved candidate (dirty tree) had its target/ stripped"
[ -e "$WT/res-clean/target/release/lastdbd" ] \
  || fail "a reserved candidate (clean tree) was stripped or removed"
printf '%s' "$out" | grep -q 'keep strip-skip reason=safe_upgrade_reservation:res-dirty.reserve' \
  || fail "the reservation skip was not logged for res-dirty"
printf '%s' "$out" | grep -q 'keep reserved safe_upgrade_reservation:res-clean.reserve' \
  || fail "the reservation keep was not logged for res-clean"

# 3. an expired reservation protects nothing.
[ ! -e "$WT/exp-dirty/target" ] \
  || fail "an expired reservation still protected target/"

echo "ok last-stack-reclaim-keeps-safe-upgrade-candidate"
