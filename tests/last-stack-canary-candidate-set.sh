#!/usr/bin/env bash
# last-stack-canary-candidate-set reads each app from its gate of record.
#
# Regression: papercut-canary-primary-rows-smoke-red-0-23-3-2375-ga7bac36f1.
# GitHub era 3 (2026-09-26/27) moved every app's gate of record to GitHub
# and froze the Forgejo copy. The set still named the Forgejo copy as the
# clone source, so an artifact head that landed after the freeze (routines
# 3bf55c676a14) was a pin its source could not serve, and every smoke was RED.
#
#   1. auto: source is the `github` URL, the artifact head and GitHub main are
#      both served, public_source is kept.
#   2. --source-venue forge: the frozen copy; its old main, and a WARNING plus
#      source_reachable=false for an artifact head it does not have.
#   3. a squash-seeded GitHub repo lacks an old pin: auto falls back to forge.
#   4. --source-venue lastgit is rejected (LastGit is retired).
# Hermetic: local bare repos stand in for GitHub and Forgejo; the `github`
# field of the fixture registry is the local bare path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-candidate-set"
work="$(mktemp -d "${TMPDIR:-/tmp}/candidate-set.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$work/home"
mkdir -p "$HOME"
export FORGE_TOKEN=unused-in-this-test

commit() {
  # commit <repo> <version>: one commit whose package.json names <version>.
  printf '{"name":"x","version":"%s"}\n' "$2" >"$1/package.json"
  git -C "$1" add package.json
  git -C "$1" -c user.name=t -c user.email=t@example.com commit --quiet -m "v$2"
  git -C "$1" rev-parse HEAD
}

# Two apps: `withart` has an artifact channel, `noart` does not.
for app in withart noart; do
  src="$work/src-$app"
  git init --quiet -b main "$src"
  commit "$src" 1.0.0 >"$work/old-$app"
  # The Forgejo copy froze here.
  git clone --quiet --bare "$src" "$work/forge-$app.git"
  commit "$src" 2.0.0 >"$work/new-$app"
  git clone --quiet --bare "$src" "$work/github-$app.git"
done

mkdir -p "$work/artifacts/channels/withart"
jq -n --arg oid "$(cat "$work/new-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"

jq -n --arg w "$work" '{apps: {
  withart: {github: ($w + "/github-withart.git"), forge: ($w + "/forge-withart.git"),
            public: "https://github.com/EdgeVector/withart.git", artifact_app: "withart", install_name: "withart"},
  noart:   {github: ($w + "/github-noart.git"), forge: ($w + "/forge-noart.git"),
            public: "https://github.com/EdgeVector/noart.git", artifact_app: null, install_name: "noart"}}}' \
  >"$work/apps.json"

cat >"$work/lastdbd" <<'EOF'
#!/bin/sh
echo "lastdbd 0.23.3-999-gtest"
EOF
chmod +x "$work/lastdbd"

run_set() {
  # run_set <out> <path> [args...]
  local out="$1" path="$2"
  shift 2
  PATH="$path" "$BIN" --lastdbd "$work/lastdbd" --apps-config "$work/apps.json" \
    --artifact-root "$work/artifacts" --cache-root "$work/cache-$(basename "$out" .json)" \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

# --- 1. auto, helper on PATH: GitHub ---------------------------------------
run_set "$work/auto.json" "$PATH" || { cat "$work/auto.json.stderr" >&2; fail "auto run failed"; }
[ "$(jq -r .apps.withart.source "$work/auto.json")" = "$work/github-withart.git" ] || fail "withart source is not GitHub"
[ "$(jq -r .apps.withart.source_venue "$work/auto.json")" = github ] || fail "withart venue"
[ "$(jq -r .apps.withart.sha "$work/auto.json")" = "$(cat "$work/new-withart")" ] || fail "withart is not at the artifact head"
[ "$(jq -r .apps.withart.sha_source "$work/auto.json")" = "artifact-channel:stable" ] || fail "withart sha_source"
[ "$(jq -r .apps.withart.source_reachable "$work/auto.json")" = true ] || fail "withart artifact head not reachable on GitHub"
[ "$(jq -r .apps.withart.app_version "$work/auto.json")" = 2.0.0 ] || fail "withart version"
[ "$(jq -r .apps.noart.sha "$work/auto.json")" = "$(cat "$work/new-noart")" ] || fail "noart is not at GitHub main"
[ "$(jq -r .apps.noart.sha_source "$work/auto.json")" = github-main ] || fail "noart sha_source"
[ "$(jq -r .apps.noart.public_source "$work/auto.json")" = "https://github.com/EdgeVector/noart.git" ] || fail "public_source changed"
[ "$(jq -r .apps.noart.forge_source "$work/auto.json")" = "$work/forge-noart.git" ] || fail "forge_source missing"
if grep -q WARNING "$work/auto.json.stderr"; then fail "auto run warned: $(cat "$work/auto.json.stderr")"; fi

# --- 1b. a GitHub repo seeded from a squash does not have a commit released
# before the cutover; the frozen Forgejo copy does (situations, 2026-09-28).
# auto falls back to Forgejo, and a warm version cache that already holds the
# commit must not hide the gap.
jq -n --arg oid "$(cat "$work/old-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"
squash="$work/src-squash"
git init --quiet -b main "$squash"
commit "$squash" 9.9.9 >"$work/squash-seed"
rm -rf "$work/github-withart.git"
git clone --quiet --bare "$squash" "$work/github-withart.git"
# Warm the cache through the Forgejo copy first.
run_set "$work/auto.json" "$PATH" --source-venue forge || { cat "$work/auto.json.stderr" >&2; fail "cache warm run failed"; }
run_set "$work/auto.json" "$PATH" || { cat "$work/auto.json.stderr" >&2; fail "squash run failed"; }
[ "$(jq -r .apps.withart.sha "$work/auto.json")" = "$(cat "$work/old-withart")" ] || fail "squash: pin moved"
[ "$(jq -r .apps.withart.source "$work/auto.json")" = "$work/forge-withart.git" ] || fail "squash: no fallback to the copy that has the commit"
[ "$(jq -r .apps.withart.source_venue "$work/auto.json")" = forge ] || fail "squash: venue"
[ "$(jq -r .apps.withart.source_fallback_from "$work/auto.json")" = github ] || fail "squash: fallback not recorded"
[ "$(jq -r .apps.withart.source_reachable "$work/auto.json")" = true ] || fail "squash: reachable"
grep -q 'NOTE withart' "$work/auto.json.stderr" || fail "squash: fallback was silent"
# Put the full-history GitHub copy and the new artifact head back.
rm -rf "$work/github-withart.git"
git clone --quiet --bare "$work/src-withart" "$work/github-withart.git"
jq -n --arg oid "$(cat "$work/new-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"

# --- 2. forge venue: the frozen copy ----------------------------------------
run_set "$work/forge.json" "$PATH" --source-venue forge || { cat "$work/forge.json.stderr" >&2; fail "forge run failed"; }
[ "$(jq -r .apps.noart.sha "$work/forge.json")" = "$(cat "$work/old-noart")" ] || fail "forge venue did not read the frozen main"
[ "$(jq -r .apps.noart.sha_source "$work/forge.json")" = forge-main ] || fail "forge sha_source"
[ "$(jq -r .apps.withart.source_reachable "$work/forge.json")" = false ] || fail "frozen copy claimed the artifact head"
grep -q 'WARNING withart' "$work/forge.json.stderr" || fail "no warning for an unreachable pin: $(cat "$work/forge.json.stderr")"

# --- 3. --source-venue lastgit is gone -------------------------------------
if run_set "$work/strict.json" "$PATH" --source-venue lastgit; then
  fail "--source-venue lastgit must be rejected (LastGit is retired)"
fi

echo "PASS last-stack-canary-candidate-set"
