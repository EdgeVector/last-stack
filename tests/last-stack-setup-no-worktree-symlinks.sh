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
git clone --quiet --no-local "$ROOT" "$canonical"
rsync -a --delete --exclude=.git "$ROOT/" "$canonical/"
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
