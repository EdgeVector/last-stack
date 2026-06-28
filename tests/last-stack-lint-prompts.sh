#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

good="$tmp/good.md"
cat > "$good" <<'GOOD'
workspace="<WORKSPACE>"
find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
  | while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      git -C "$repo" rev-parse --show-toplevel
      git -C "$repo" worktree list --porcelain
      repo_status="$(git -C "$repo" status --porcelain)"
    done
GOOD
"$ROOT/bin/last-stack-lint-prompts" "$good"

bad_status="$tmp/bad-status.md"
printf '%s\n' "fbrain doctor >/dev/null; stat""us=\$?; echo \"\$stat""us\"" > "$bad_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_status" >/dev/null 2>&1; then
  echo "expected reserved status assignment to fail prompt lint" >&2
  exit 1
fi

bad_workspace_git="$tmp/bad-workspace-git.md"
{
  printf '%s\n' "pwd && git stat""us --short --branch"
  printf '%s\n' "git -C /Users/tomtang/code/edge""vector status --short"
  printf '%s\n' "git work""tree list --porcelain"
} > "$bad_workspace_git"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_git" >/dev/null 2>&1; then
  echo "expected unsafe workspace/root Git probes to fail prompt lint" >&2
  exit 1
fi

if command -v zsh >/dev/null 2>&1; then
  zsh -fc 'fbrain() { return 7; }; fbrain doctor >/dev/null 2>&1; doctor_status=$?; test "$doctor_status" -eq 7'
fi

echo "ok"
