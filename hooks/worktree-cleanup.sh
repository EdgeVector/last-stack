#!/usr/bin/env bash
# Stop hook: when a Claude session ends inside a .claude/worktrees/<name>/
# git worktree, prune the worktree IFF the working tree is clean AND
# there are no unpushed commits. Conservative — would rather leak a
# worktree than delete uncommitted WIP.
#
# Companion to the worktree-janitor in exemem-workspace, which sweeps the
# leaks from sessions that got SIGKILL'd before this hook could fire.

set -u

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"

# Only fire for Claude-managed session worktrees
case "$cwd" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

[ -d "$cwd" ] || exit 0

cd "$cwd" 2>/dev/null || exit 0

# Confirm it's actually a git worktree (not the main repo)
common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
git_dir="$(git rev-parse --git-dir 2>/dev/null || echo "")"
[ -n "$common_dir" ] && [ -n "$git_dir" ] || exit 0
common_real="$(/bin/sh -c "cd '$common_dir' 2>/dev/null && pwd -P" 2>/dev/null || echo "")"
git_real="$(/bin/sh -c "cd '$git_dir' 2>/dev/null && pwd -P" 2>/dev/null || echo "")"
[ -n "$common_real" ] && [ -n "$git_real" ] || exit 0
[ "$common_real" = "$git_real" ] && exit 0  # main worktree, not a child

# Working tree must be clean — if there's untracked, modified, or staged
# work, leave the worktree alone. The user can come back to it.
[ -z "$(git status --porcelain 2>/dev/null)" ] || exit 0

# Branch must have an upstream and be at-or-behind it (no unpushed commits)
branch="$(git branch --show-current 2>/dev/null || echo "")"
[ -n "$branch" ] || exit 0

upstream="$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")"
[ -n "$upstream" ] || exit 0

ahead="$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 999)"
[ "$ahead" = "0" ] || exit 0

# All conditions met — remove the worktree from the parent repo's perspective
parent_repo="$(/bin/sh -c "cd '$common_dir/..' 2>/dev/null && pwd -P" 2>/dev/null || echo "")"
[ -n "$parent_repo" ] && [ -d "$parent_repo/.git" ] || exit 0

( cd "$parent_repo" && git worktree remove "$cwd" >/dev/null 2>&1 ) || true

exit 0
