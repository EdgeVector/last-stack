#!/usr/bin/env bash
set -euo pipefail

# Isolate from host git config: a global url.<token>.insteadOf rewrite or
# credential helper would leak into remote get-url output and fail the
# assertions below on exactly the machines this tool exists to clean up.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

repo="$tmp/workspace/example"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
touch "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m initial >/dev/null

git -C "$repo" remote add origin 'https://x-access-token:dummy-token-placeholder@github.com/EdgeVector/example.git'
git -C "$repo" remote set-url --push origin 'https://x-access-token:dummy-token-placeholder@github.com/EdgeVector/example.git'

if "$ROOT/bin/last-stack-scrub-github-token-remotes" --check "$tmp/workspace" >"$tmp/check.out"; then
  echo "expected check mode to detect embedded-token remotes" >&2
  exit 1
fi
grep -q $'^would-scrub\t' "$tmp/check.out"
if grep -q 'dummy-token-placeholder' "$tmp/check.out"; then
  echo "check output leaked token-bearing remote material" >&2
  exit 1
fi

"$ROOT/bin/last-stack-scrub-github-token-remotes" "$tmp/workspace" >"$tmp/apply.out"
grep -q $'^scrubbed\t' "$tmp/apply.out"
test "$(git -C "$repo" remote get-url origin)" = 'https://github.com/EdgeVector/example.git'
test "$(git -C "$repo" config --get-all remote.origin.pushurl)" = 'https://github.com/EdgeVector/example.git'
test "$(git -C "$repo" config --get credential.https://github.com.helper)" = '!gh auth git-credential'

"$ROOT/bin/last-stack-scrub-github-token-remotes" --check "$tmp/workspace" >"$tmp/clean.out"
grep -q $'^ok\tchecked=1\tscrubbed=0$' "$tmp/clean.out"

echo "ok"
