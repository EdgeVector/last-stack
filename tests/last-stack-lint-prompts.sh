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

bad_gh_release="$tmp/bad-gh-release.md"
printf '%s\n' "gh release view --repo owner/repo --json tagName,is""Latest,isPrerelease" > "$bad_gh_release"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_release" >/dev/null 2>&1; then
  echo "expected unsupported gh release isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

memory_home="$tmp/home"
mkdir -p "$memory_home"
env -u CODEX_HOME HOME="$memory_home" bash -eu <<'SH'
automation_id="last-stack-smoke"
memory_path=""
if [ -z "$memory_path" ]; then
  memory_path="${CODEX_HOME:-$HOME/.codex}/automations/$automation_id/memory.md"
fi
case "$memory_path" in
  ""|/automations/*) echo "unsafe automation memory path: $memory_path" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$memory_path")"
touch "$memory_path"
test "$memory_path" = "$HOME/.codex/automations/$automation_id/memory.md"
test -f "$memory_path"
SH

if command -v zsh >/dev/null 2>&1; then
  zsh -fc 'fbrain() { return 7; }; fbrain doctor >/dev/null 2>&1; doctor_status=$?; test "$doctor_status" -eq 7'
fi

echo "ok"
