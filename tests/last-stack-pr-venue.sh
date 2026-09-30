#!/usr/bin/env bash
set -euo pipefail

# Every scheduled routine on this fleet exports LAST_STACK_LASTGIT_NATIVE_REPOS
# (the era-3 migrated-repo list) into its dispatch shell, and that list
# already names EdgeVector/last-stack, EdgeVector/loom, EdgeVector/fkanban,
# EdgeVector/routines. Left ambient, it wins over this test's own fixture
# marker-less repos, so the "defaults without marker" assertions below read
# lastgit instead of forgejo -- passing only in a shell that happens not to
# have the var set, and failing deterministically inside real CI/routine runs
# where it always is. Unset it (and its forgejo counterpart) so this test
# exercises the fallback logic in isolation, the same env every assertion
# below assumes.
unset LAST_STACK_LASTGIT_NATIVE_REPOS LAST_STACK_FORGEJO_REPOS

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

# The host environment can carry a real, live LAST_STACK_LASTGIT_NATIVE_REPOS
# (set ambient by routinesd/launchd as repos migrate venue) that would leak
# into the "defaults without marker" checks below and make this fixture
# depend on today's live migration state instead of the tool's own default
# logic. Unset it so every assertion in this file tests the code path, not
# the machine it happens to run on.
unset LAST_STACK_LASTGIT_NATIVE_REPOS

# Defaults without marker. 2026-09-30 (Tom): every EdgeVector repo is on GitHub,
# including an unknown one. Only the `lastgit` repo stays on Forgejo. LastGit is
# retired (decision-2026-09-29-retire-lastgit-all-repos-to-github).
for name in last-stack fkanban routines loom brain fold exemem-infra schema-infra configurations situations never-heard-of-it Keepside_Desktop; do
  test "$("$ROOT/bin/last-stack-pr-venue" "EdgeVector/$name" "$repo")" = "github" \
    || { echo "FAIL: EdgeVector/$name must default to github" >&2; exit 1; }
done
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/lastgit "$repo")" = "forgejo"
test "$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/lastgit "$repo" | jq -r .reason)" = "default:forgejo-lastgit-repo"
test "$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/never-heard-of-it "$repo" | jq -r .reason)" = "default:github"
# No repo root at all still answers github (a routine shell has none).
test "$("$ROOT/bin/last-stack-pr-venue" EdgeVector/loom)" = "github"
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "origin/main"

# An ambient LAST_STACK_LASTGIT_NATIVE_REPOS (set in every routine shell) must not
# bring the retired venue back. It counts only with LAST_STACK_LASTGIT_ENABLED=1.
test "$(LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/last-stack EdgeVector/loom" "$ROOT/bin/last-stack-pr-venue" EdgeVector/loom "$repo")" = "github"
test "$(LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/loom" "$ROOT/bin/last-stack-pr-venue" EdgeVector/loom)" = "github"
# An explicit repo-local venue still wins over the default, and the env forgejo list works.
test "$(LAST_STACK_FORGEJO_REPOS="EdgeVector/loom" "$ROOT/bin/last-stack-pr-venue" EdgeVector/loom)" = "forgejo"

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
# LastGit is retired: even LAST_STACK_LASTGIT_ENABLED=1 with a native list cannot bring it back.
test "$(LAST_STACK_LASTGIT_ENABLED=1 LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/last-stack EdgeVector/other" "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "github"

printf '%s\n' "not-a-venue" > "$repo/.last-stack/pr-venue"
if "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo" >/dev/null 2>"$tmp/bad.err"; then
  echo "expected invalid marker venue to fail" >&2
  exit 1
fi
grep -q "unsupported venue" "$tmp/bad.err"

echo "ok"
