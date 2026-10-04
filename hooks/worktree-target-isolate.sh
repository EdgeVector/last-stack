#!/usr/bin/env bash
# SessionStart hook: give each kanban/gstack worktree its OWN cargo target
# dir instead of a symlink into the shared ~/code/edgevector/fold/target
# (and fold_dev_node/target).
#
# Why: the cline/gstack worktree tooling symlinks every worktree's `target`
# into one shared dir. Cargo never GCs it, so it grows to hundreds of GB,
# and removing a worktree reclaims nothing (the symlink just unlinks). With
# a real per-worktree target, `git worktree remove` (and the nightly
# machine-hygiene sweep) actually reclaim the disk. sccache (the global
# rustc-wrapper) still shares *compilation* across worktrees, so the only
# added cost is re-linking, not recompiling.
#
# Safety: only fires inside a worktree path, and only rewrites a `target`
# that is a SYMLINK pointing at a shared */fold/target or
# */fold_dev_node/target. Removing the symlink never deletes the shared
# dir's contents. The real main checkout (cwd not under a worktree) is
# untouched. See memory: project_disk_shared_fold_target.
set -u

input="$(cat 2>/dev/null || echo '')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo '')"
[ -n "$cwd" ] || exit 0

# Only act inside Claude/cline-managed worktrees.
case "$cwd" in
  */.cline/worktrees/*|*/.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

for t in "$cwd"/target "$cwd"/fold/target "$cwd"/fold_dev_node/target; do
  [ -L "$t" ] || continue
  dest="$(readlink "$t" 2>/dev/null || echo '')"
  case "$dest" in
    */fold/target|*/fold_dev_node/target)
      rm -f "$t" 2>/dev/null && mkdir -p "$t" 2>/dev/null
      ;;
  esac
done

exit 0
