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

# An explicit `lastgit` git config is a RETIRED venue. By default it is ignored
# and the caller gets an actionable venue; the ignored value stays visible on
# stderr and in --json. Honoring it needs LAST_STACK_LASTGIT_ENABLED=1.
# papercut-portal-pr-venue-stubs-still-say-lastgit-20260923
json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo" 2>"$tmp/gate.err")"
printf '%s\n' "$json" | jq -e '.venue == "github"' >/dev/null \
  || { echo "FAIL: retired lastgit git-config must not be honored by default" >&2; exit 1; }
printf '%s\n' "$json" | jq -e '.reason == "default:github"' >/dev/null
printf '%s\n' "$json" | jq -e '.ignored_venue == "lastgit"' >/dev/null \
  || { echo "FAIL: the ignored venue must stay visible in --json" >&2; exit 1; }
printf '%s\n' "$json" | jq -e '.ignored_venue_source == "git-config:laststack.pr-venue"' >/dev/null \
  || { echo "FAIL: --json must name the source that carried the retired venue" >&2; exit 1; }
grep -q "ignoring retired venue 'lastgit'" "$tmp/gate.err" \
  || { echo "FAIL: ignoring a retired venue must warn on stderr" >&2; exit 1; }
# compare-ref follows the resolved venue, so it must not point at lastgit/main.
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo" 2>/dev/null)" = "origin/main"

# Opt-in restores the pre-retirement contract exactly, slug and ci-context included.
json="$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo")"
printf '%s\n' "$json" | jq -e '.venue == "lastgit"' >/dev/null
printf '%s\n' "$json" | jq -e '.lastgit_slug == "last-stack-shadow"' >/dev/null
printf '%s\n' "$json" | jq -e '.ci_context == "smoke-required"' >/dev/null
printf '%s\n' "$json" | jq -e '.compare_ref == "lastgit/main"' >/dev/null
printf '%s\n' "$json" | jq -e '.ignored_venue == ""' >/dev/null \
  || { echo "FAIL: nothing is ignored when the opt-in is set" >&2; exit 1; }
test "$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "lastgit/main"
test "$(git -C "$repo" rev-list --count "$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")"..HEAD)" = "0"

# The gate must fire ONLY on the retired venue. A live venue carried by the very
# same git config must pass through untouched, with nothing reported as ignored
# -- this is what goes red if the gate is ever widened past `lastgit`.
git -C "$repo" config laststack.pr-venue forgejo
json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo")"
printf '%s\n' "$json" | jq -e '.venue == "forgejo"' >/dev/null \
  || { echo "FAIL: a live forgejo git config must still be honored" >&2; exit 1; }
printf '%s\n' "$json" | jq -e '.reason == "git-config:laststack.pr-venue"' >/dev/null
printf '%s\n' "$json" | jq -e '.ignored_venue == ""' >/dev/null \
  || { echo "FAIL: a live venue must never be reported as ignored" >&2; exit 1; }
git -C "$repo" config laststack.pr-venue lastgit

git -C "$repo" update-ref -d refs/remotes/lastgit/main
test "$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "origin/main"
git -C "$repo" update-ref refs/remotes/lastgit/main "$lastgit_head"

git -C "$repo" config --unset laststack.pr-venue
mkdir -p "$repo/.last-stack"
printf '%s\n' "lastgit" > "$repo/.last-stack/pr-venue"
# The marker door is the one an agent hits by following CLAUDE.md with a stale
# repo root (the install root carried a Jul-21 `lastgit` marker and both retired
# remotes). Default: ignored, and the source named is the marker, not git config.
json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo" 2>"$tmp/marker.err")"
printf '%s\n' "$json" | jq -e '.venue == "github"' >/dev/null \
  || { echo "FAIL: a retired lastgit marker must not be honored by default" >&2; exit 1; }
printf '%s\n' "$json" | jq -e '.ignored_venue_source == ".last-stack/pr-venue"' >/dev/null \
  || { echo "FAIL: --json must name the marker as the source" >&2; exit 1; }
grep -q "ignoring retired venue 'lastgit'" "$tmp/marker.err"
test "$("$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo" 2>/dev/null)" = "origin/main"
# Opt-in restores it.
test "$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" EdgeVector/last-stack "$repo")" = "lastgit"
test "$(LAST_STACK_LASTGIT_ENABLED=1 "$ROOT/bin/last-stack-pr-venue" --compare-ref EdgeVector/last-stack "$repo")" = "lastgit/main"
# A live venue in the marker is untouched, and reports nothing ignored.
printf '%s\n' "github" > "$repo/.last-stack/pr-venue"
json="$("$ROOT/bin/last-stack-pr-venue" --json EdgeVector/last-stack "$repo")"
printf '%s\n' "$json" | jq -e '.venue == "github" and .reason == ".last-stack/pr-venue"' >/dev/null
printf '%s\n' "$json" | jq -e '.ignored_venue == ""' >/dev/null \
  || { echo "FAIL: a live marker venue must never be reported as ignored" >&2; exit 1; }
printf '%s\n' "lastgit" > "$repo/.last-stack/pr-venue"

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
