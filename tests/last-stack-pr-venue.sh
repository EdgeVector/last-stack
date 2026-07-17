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
git -C "$repo" branch -M main
initial_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$initial_head"

# Defaults without marker (2026-07-17): most EdgeVector repos are LastGit-native;
# GitHub copies are read-only mirrors. Do not default public repos to github.
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/fold "$repo")" = "forgejo"
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/lastgit "$repo")" = "forgejo"
# exemem-infra cut over to LastGit (GitHub is read-only mirror / deploy artifact only).
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/exemem-infra "$repo")" = "lastgit"
# True GitHub primaries still default to github.
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/Keepside_Desktop "$repo")" = "github"
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "origin/main"

git -C "$repo" config laststack.pr-venue lastgit
git -C "$repo" config laststack.lastgit-slug last-stack-shadow
git -C "$repo" config laststack.lastgit-ci-context smoke-required
printf '%s\n' changed > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m changed >/dev/null
lastgit_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/lastgit/main "$lastgit_head"

json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo")"
printf '%s\n' "$json" | jq -e '.venue == "lastgit"' >/dev/null
printf '%s\n' "$json" | jq -e '.lastgit_slug == "last-stack-shadow"' >/dev/null
printf '%s\n' "$json" | jq -e '.ci_context == "smoke-required"' >/dev/null
printf '%s\n' "$json" | jq -e '.compare_ref == "lastgit/main"' >/dev/null
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "lastgit/main"
test "$(git -C "$repo" rev-list --count "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")"..HEAD)" = "0"

git -C "$repo" update-ref -d refs/remotes/lastgit/main
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "origin/main"
git -C "$repo" update-ref refs/remotes/lastgit/main "$lastgit_head"

git -C "$repo" config --unset laststack.pr-venue
mkdir -p "$repo/.last-stack"
printf '%s\n' "lastgit" > "$repo/.last-stack/pr-venue"
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "lastgit/main"

rm "$repo/.last-stack/pr-venue"
test "$(LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/last-stack EdgeVector/other" "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"

printf '%s\n' "not-a-venue" > "$repo/.last-stack/pr-venue"
if "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo" >/dev/null 2>"$tmp/bad.err"; then
  echo "expected invalid marker venue to fail" >&2
  exit 1
fi
grep -q "unsupported venue" "$tmp/bad.err"

echo "ok"
