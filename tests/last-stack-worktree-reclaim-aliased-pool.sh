#!/usr/bin/env bash
# ~/.kanban is a symlink to ~/.fkanban on this host. The reclaim helper used
# to walk both paths as two pools, keep-protect a tree on the first listing,
# then rm-orphan the same inode on the second listing.
# papercut-worktree-reclaim-aliased-pool-drops-protect
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-worktree-reclaim"
chmod +x "$bin" 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-alias.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

git_bin=/usr/bin/git
[ -x "$git_bin" ] || git_bin="$(command -v git)"

# Isolated HOME so the helper takes the default two-root pair, not WORKTREES_DIR.
# WORKTREES_DIR is the test override that already collapses to one root — this
# fixture must not set it, or it cannot see the dual-walk defect.
export HOME="$tmp/home"
unset WORKTREES_DIR
mkdir -p "$HOME/.fkanban/worktrees"
ln -s "$HOME/.fkanban" "$HOME/.kanban"

name="fold-kanban-protected-alias-tree"
wt="$HOME/.fkanban/worktrees/$name"
mkdir -p "$wt"
"$git_bin" -C "$wt" init -q -b main
"$git_bin" -C "$wt" -c user.email=t@example.com -c user.name=t \
  commit -q --allow-empty -m init
# Older than the 60-minute grace so the finished-work path is reachable.
touch -t 202001010000 "$wt"

# Protect via the live-path index, not a doing-card slug. Live cwd is recorded
# as the realpath (~/.fkanban/...). The second walk lists ~/.kanban/... which
# is the same inode but a different string, so the live index does not match
# — that is the measured producer of the drop.
: >"$tmp/open-heads.tsv"
export LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$tmp/open-heads.tsv"
export LAST_STACK_RECLAIM_SKIP_BOARD=1
export LAST_STACK_RECLAIM_SKIP_LSOF=1
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0
export LAST_STACK_RECLAIM_EXTRA_LIVE_PATHS="$wt"
export LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches"
mkdir -p "$tmp/patches"

run_sweep() {
  local helper="$1"
  HOME="$HOME" \
    LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$LAST_STACK_RECLAIM_OPEN_HEADS_FILE" \
    LAST_STACK_RECLAIM_SKIP_BOARD=1 \
    LAST_STACK_RECLAIM_SKIP_LSOF=1 \
    LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0 \
    LAST_STACK_RECLAIM_EXTRA_LIVE_PATHS="$wt" \
    LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches" \
    "$helper" --sweep-stale --min-age-minutes 0 --max-age-hours 99999 2>&1 || true
}

out="$(run_sweep "$bin")"
printf '%s\n' "$out" | grep -E 'aliased|protected-alias|rm orphan|reclaim finished' || true

if [ ! -d "$wt" ]; then
  echo "FAIL: unique-root helper dropped the protected aliased tree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q "rm orphan"; then
  echo "FAIL: unique-root helper logged rm orphan for a protected tree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q "reclaim finished ${name}"; then
  echo "FAIL: unique-root helper reclaimed a live-protected tree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q "keep protected ${name}"; then
  echo "FAIL: unique-root helper did not keep the protected tree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q "skip aliased worktree root"; then
  echo "FAIL: unique-root helper did not collapse the aliased kanban root" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "ok unique-root keeps the protected aliased tree"

# Negative: revert the unique-root collapse. The same fixture must then drop
# the tree (keep protected on the fkanban listing, then rm/reclaim on the
# kanban listing of the same inode).
bad="$tmp/reclaim-without-unique"
python3 - "$bin" "$bad" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
pat = re.compile(
    r"# unique-worktree-roots-start.*?# unique-worktree-roots-end\n",
    re.S,
)
new, n = pat.subn("# unique-worktree-roots stripped for negative fixture\n", src, count=1)
if n != 1:
    sys.stderr.write("FAIL: unique-worktree-roots markers missing in helper\n")
    sys.exit(1)
out.write_text(new)
out.chmod(0o755)
PY

# Replant: the positive run kept the tree; make sure it is still a clean git
# dir older than grace before the broken helper walks it twice.
if [ ! -d "$wt/.git" ]; then
  echo "FAIL: positive run left the fixture unrestorable" >&2
  exit 1
fi
touch -t 202001010000 "$wt"

out_bad="$(run_sweep "$bad")"
printf '%s\n' "$out_bad" | grep -E 'keep protected|reclaim finished|rm orphan|force-rm' || true

dropped=0
if [ ! -d "$wt" ]; then
  dropped=1
fi
if printf '%s\n' "$out_bad" | grep -q "rm orphan"; then
  dropped=1
fi
if printf '%s\n' "$out_bad" | grep -q "reclaim finished ${name}"; then
  dropped=1
fi
if printf '%s\n' "$out_bad" | grep -q "force-rm worktree"; then
  dropped=1
fi
if [ "$dropped" -ne 1 ]; then
  echo "FAIL: reverting unique-root must drop the protected aliased tree" >&2
  printf '%s\n' "$out_bad" >&2
  exit 1
fi
if ! printf '%s\n' "$out_bad" | grep -q "keep protected ${name}"; then
  echo "FAIL: negative helper never keep-protected on the first listing" >&2
  printf '%s\n' "$out_bad" >&2
  exit 1
fi
echo "ok negative dual-walk drops the same tree (unique-root is the fix)"
echo "PASS last-stack-worktree-reclaim-aliased-pool"
