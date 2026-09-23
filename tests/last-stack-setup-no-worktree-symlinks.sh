#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
canonical="$HOME/.last-stack"
scratch="$tmp/scratch-last-stack"

mkdir -p "$HOME/.claude"
# Linux CI mounts the source checkout with a host owner.  Git accepts
# safe.directory only from protected configuration, so use a fixture-local
# global configuration for the root and its git directory.
fixture_git_config="$tmp/gitconfig"
GIT_CONFIG_GLOBAL="$fixture_git_config" git config --global --add safe.directory "$ROOT"
GIT_CONFIG_GLOBAL="$fixture_git_config" git config --global --add safe.directory "$ROOT/.git"
GIT_CONFIG_GLOBAL="$fixture_git_config" git clone --quiet --no-local "$ROOT" "$canonical"
# The production image has rsync.  The minimal Linux gate image does not.
# Copy the current source after the clone so this test also covers local edits.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude=.git "$ROOT/" "$canonical/"
else
  # A binary Git patch preserves the clone metadata and carries tracked
  # additions, edits, and deletions from the current source tree.
  source_patch="$tmp/source.patch"
  GIT_CONFIG_GLOBAL="$fixture_git_config" git -C "$ROOT" diff --binary HEAD >"$source_patch"
  if [ -s "$source_patch" ]; then
    git -C "$canonical" apply --whitespace=nowarn "$source_patch"
  fi
fi
git -C "$canonical" config user.email "last-stack-test@example.invalid"
git -C "$canonical" config user.name "Last Stack Test"
git -C "$canonical" add -A
if ! git -C "$canonical" diff --cached --quiet; then
  git -C "$canonical" commit --quiet -m "test current working tree"
fi
git -C "$canonical" worktree add --quiet "$scratch" HEAD
canonical_real="$(cd "$canonical" && pwd -P)"
scratch_real="$(cd "$scratch" && pwd -P)"

(
  cd "$scratch"
  ./setup --host claude >"$tmp/setup.out"
)

bad_links="$(
  find "$HOME/.claude/skills" -type l -print | while IFS= read -r link; do
    dest="$(readlink "$link")"
    case "$dest" in
      "$canonical_real"/*) ;;
      "$scratch_real"/*|*/.kanban/worktrees/*|*/.fkanban/worktrees/*) printf '%s -> %s\n' "$link" "$dest" ;;
      *) printf '%s -> %s\n' "$link" "$dest" ;;
    esac
  done
)"

if [ -n "$bad_links" ]; then
  printf 'unexpected non-canonical skill links:\n%s\n' "$bad_links" >&2
  exit 1
fi

git -C "$canonical" worktree remove --force "$scratch"

broken_links="$(find "$HOME/.claude/skills" -type l ! -exec test -e {} \; -print)"
if [ -n "$broken_links" ]; then
  printf 'broken skill links after scratch worktree removal:\n%s\n' "$broken_links" >&2
  exit 1
fi

echo "ok"
