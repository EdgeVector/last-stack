#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
touch "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m initial >/dev/null

test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "github"
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/fold "$repo")" = "forgejo"
# exemem-infra is GitHub-primary since 2026-07-13 (decision-2026-07-13-exemem-infra-github-primary);
# its forge copy is retired + archived, so it must NOT route to the forge.
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/exemem-infra "$repo")" = "github"

git -C "$repo" config laststack.pr-venue lastgit
git -C "$repo" config laststack.lastgit-slug last-stack-shadow
git -C "$repo" config laststack.lastgit-ci-context smoke-required

json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo")"
printf '%s\n' "$json" | jq -e '.venue == "lastgit"' >/dev/null
printf '%s\n' "$json" | jq -e '.lastgit_slug == "last-stack-shadow"' >/dev/null
printf '%s\n' "$json" | jq -e '.ci_context == "smoke-required"' >/dev/null

git -C "$repo" config --unset laststack.pr-venue
mkdir -p "$repo/.last-stack"
printf '%s\n' "lastgit" > "$repo/.last-stack/pr-venue"
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"

rm "$repo/.last-stack/pr-venue"
test "$(LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/last-stack EdgeVector/other" "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"

printf '%s\n' "not-a-venue" > "$repo/.last-stack/pr-venue"
if "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo" >/dev/null 2>"$tmp/bad.err"; then
  echo "expected invalid marker venue to fail" >&2
  exit 1
fi
grep -q "unsupported venue" "$tmp/bad.err"

echo "ok"
