#!/usr/bin/env bash
# The candidate set reads an app's gate of record from its `github` field
# (2026-09-30: every app moved to GitHub, LastGit is retired). Fixture only: a
# local bare repo stands in for the GitHub URL. No network.
#   1. auto: source is the `github` URL, venue github, no git-remote-lastdb needed.
#   2. --source-venue github without a `github` field is refused.
#   3. an app with `github` never reads a stale `lastgit`/`forge` copy first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-candidate-set"
work="$(mktemp -d "${TMPDIR:-/tmp}/candidate-set-gh.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$work/home"
mkdir -p "$HOME"

src="$work/src"
git init --quiet -b main "$src"
printf '{"name":"x","version":"3.0.0"}\n' >"$src/package.json"
git -C "$src" add package.json
git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet -m v3
git clone --quiet --bare "$src" "$work/gh-moved.git"
git clone --quiet --bare "$src" "$work/stale-forge-moved.git"
# The frozen copy is older: it must not be the source.
git -C "$work/stale-forge-moved.git" update-ref refs/heads/main "$(git -C "$src" rev-parse HEAD)"

jq -n --arg w "$work" '{apps: {
  moved: {github: ($w + "/gh-moved.git"), forge: ($w + "/stale-forge-moved.git"),
          public: "https://github.com/EdgeVector/moved.git", artifact_app: null, install_name: "moved"},
  legacy: {forge: ($w + "/stale-forge-moved.git"),
          public: "https://github.com/EdgeVector/legacy.git", artifact_app: null, install_name: "legacy"}}}' \
  >"$work/apps.json"

printf '#!/bin/sh\necho "lastdbd 0.23.3-999-gtest"\n' >"$work/lastdbd"
chmod +x "$work/lastdbd"

run_set() {
  local out="$1"
  shift
  PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" "$BIN" --lastdbd "$work/lastdbd" --apps-config "$work/apps.json" \
    --artifact-root "$work/artifacts" --cache-root "$work/cache-$(basename "$out" .json)" \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

run_set "$work/auto.json" --only moved || { cat "$work/auto.json.stderr" >&2; fail "auto run failed"; }
[ "$(jq -r .apps.moved.source "$work/auto.json")" = "$work/gh-moved.git" ] || fail "source is not the github field"
[ "$(jq -r .apps.moved.source_venue "$work/auto.json")" = github ] || fail "venue is not github"
[ "$(jq -r .apps.moved.sha_source "$work/auto.json")" = github-main ] || fail "sha_source is not github-main"
[ "$(jq -r .apps.moved.source_reachable "$work/auto.json")" = true ] || fail "pin not reachable on github"

run_set "$work/gh.json" --only moved --source-venue github || fail "--source-venue github failed"
[ "$(jq -r .apps.moved.source_venue "$work/gh.json")" = github ] || fail "explicit github venue"

if run_set "$work/nogh.json" --only legacy --source-venue github; then
  fail "--source-venue github must refuse an app with no github field"
fi
grep -q 'no `github` field' "$work/nogh.json.stderr" || fail "no reason printed: $(cat "$work/nogh.json.stderr")"

# An app with only a forge field still works (the legacy fallback).
run_set "$work/legacy.json" --only legacy || fail "legacy auto run failed"
[ "$(jq -r .apps.legacy.source_venue "$work/legacy.json")" = forge ] || fail "legacy venue"

# The shipped registry: every moved app names GitHub and no retired venue.
bad="$(jq -r '.apps | to_entries[] | select(.key != "org")
  | select((.value.github // "") == "" or (.value | has("lastgit")) or (.value | has("forge"))) | .key' \
  "$ROOT/config/registry/apps.json")"
[ -z "$bad" ] || fail "registry apps still on a retired venue: $bad"
# The safe-upgrade CLI defaults every app to its GitHub repo.
if grep -n 'DEFAULT_REMOTE=.*\(lastdb:///\|localhost:3300\)' "$ROOT/bin/last-stack-safe-upgrade-cli"; then
  fail "last-stack-safe-upgrade-cli still defaults to LastGit or Forgejo"
fi

echo "ok last-stack-canary-candidate-set-github"
