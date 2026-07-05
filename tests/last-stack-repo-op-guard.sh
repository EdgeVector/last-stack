#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

workspace="$tmp/workspace"
repo="$workspace/last-stack"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
touch "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m initial >/dev/null

resolved="$("$ROOT/bin/last-stack-repo-op-guard" "$repo" "$workspace")"
test "$resolved" = "$(cd "$repo" && pwd -P)"

subdir="$repo/docs"
mkdir -p "$subdir"
resolved_subdir="$("$ROOT/bin/last-stack-repo-op-guard" "$subdir" "$workspace")"
test "$resolved_subdir" = "$(cd "$repo" && pwd -P)"

if "$ROOT/bin/last-stack-repo-op-guard" "$workspace" "$workspace" >/dev/null 2>"$tmp/workspace.err"; then
  echo "expected aggregate workspace root to be rejected" >&2
  exit 1
fi
grep -q 'refusing aggregate workspace root' "$tmp/workspace.err"

if "$ROOT/bin/last-stack-repo-op-guard" "$tmp/not-a-repo" "$workspace" >/dev/null 2>"$tmp/missing.err"; then
  echo "expected missing path to be rejected" >&2
  exit 1
fi
grep -q 'path is not a directory' "$tmp/missing.err"

mkdir -p "$workspace/not-a-repo"
if "$ROOT/bin/last-stack-repo-op-guard" "$workspace/not-a-repo" "$workspace" >/dev/null 2>"$tmp/not-repo.err"; then
  echo "expected non-git path to be rejected" >&2
  exit 1
fi
grep -q 'path is not a Git checkout' "$tmp/not-repo.err"

echo "ok"
