#!/usr/bin/env bash
# last-stack-canary-candidate-set reads each app from its gate of record.
#
# Regression: papercut-canary-primary-rows-smoke-red-0-23-3-2375-ga7bac36f1.
# LastGit era 3 (2026-09-26/27) moved every app's gate of record to LastGit
# and froze the Forgejo copy. The set still named the Forgejo copy as the
# clone source, so an artifact head that landed after the freeze (routines
# 3bf55c676a14) was a pin its source could not serve, and every smoke was RED.
#
#   1. auto + git-remote-lastdb on PATH: source is the `lastgit` URL, the
#      artifact head and LastGit main are both served, public_source is kept.
#   2. --source-venue forge: the frozen copy; its old main, and a WARNING plus
#      source_reachable=false for an artifact head it does not have.
#   3. auto without the helper: falls back to forge and says so.
# Hermetic: local bare repos stand in for LastGit and Forgejo; a git
# insteadOf rewrite maps lastdb:///<repo> to the local "LastGit" repo.
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
  git clone --quiet --bare "$src" "$work/lastgit-$app.git"
done

mkdir -p "$work/artifacts/channels/withart"
jq -n --arg oid "$(cat "$work/new-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"

jq -n --arg w "$work" '{apps: {
  withart: {lastgit: "lastdb:///withart", forge: ($w + "/forge-withart.git"),
            public: "https://github.com/EdgeVector/withart.git", artifact_app: "withart", install_name: "withart"},
  noart:   {lastgit: "lastdb:///noart", forge: ($w + "/forge-noart.git"),
            public: "https://github.com/EdgeVector/noart.git", artifact_app: null, install_name: "noart"}}}' \
  >"$work/apps.json"

cat >"$work/lastdbd" <<'EOF'
#!/bin/sh
echo "lastdbd 0.23.3-999-gtest"
EOF
chmod +x "$work/lastdbd"

helper_bin="$work/helper-bin"
mkdir -p "$helper_bin"
printf '#!/bin/sh\necho "fixture helper must not run (insteadOf rewrites the URL)" >&2\nexit 1\n' >"$helper_bin/git-remote-lastdb"
chmod +x "$helper_bin/git-remote-lastdb"

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.$work/lastgit-withart.git.insteadOf" GIT_CONFIG_VALUE_0="lastdb:///withart"
export GIT_CONFIG_KEY_1="url.$work/lastgit-noart.git.insteadOf" GIT_CONFIG_VALUE_1="lastdb:///noart"

run_set() {
  # run_set <out> <path> [args...]
  local out="$1" path="$2"
  shift 2
  PATH="$path" "$BIN" --lastdbd "$work/lastdbd" --apps-config "$work/apps.json" \
    --artifact-root "$work/artifacts" --cache-root "$work/cache-$(basename "$out" .json)" \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

# --- 1. auto, helper on PATH: LastGit ---------------------------------------
run_set "$work/auto.json" "$helper_bin:$PATH" || { cat "$work/auto.json.stderr" >&2; fail "auto run failed"; }
[ "$(jq -r .apps.withart.source "$work/auto.json")" = "lastdb:///withart" ] || fail "withart source is not LastGit"
[ "$(jq -r .apps.withart.source_venue "$work/auto.json")" = lastgit ] || fail "withart venue"
[ "$(jq -r .apps.withart.sha "$work/auto.json")" = "$(cat "$work/new-withart")" ] || fail "withart is not at the artifact head"
[ "$(jq -r .apps.withart.sha_source "$work/auto.json")" = "artifact-channel:stable" ] || fail "withart sha_source"
[ "$(jq -r .apps.withart.source_reachable "$work/auto.json")" = true ] || fail "withart artifact head not reachable on LastGit"
[ "$(jq -r .apps.withart.app_version "$work/auto.json")" = 2.0.0 ] || fail "withart version"
[ "$(jq -r .apps.noart.sha "$work/auto.json")" = "$(cat "$work/new-noart")" ] || fail "noart is not at LastGit main"
[ "$(jq -r .apps.noart.sha_source "$work/auto.json")" = lastgit-main ] || fail "noart sha_source"
[ "$(jq -r .apps.noart.public_source "$work/auto.json")" = "https://github.com/EdgeVector/noart.git" ] || fail "public_source changed"
[ "$(jq -r .apps.noart.forge_source "$work/auto.json")" = "$work/forge-noart.git" ] || fail "forge_source missing"
if grep -q WARNING "$work/auto.json.stderr"; then fail "auto run warned: $(cat "$work/auto.json.stderr")"; fi

# --- 1b. a LastGit repo seeded from a squash does not have a commit released
# before the cutover; the frozen Forgejo copy does (situations, 2026-09-28).
# auto falls back to Forgejo, and a warm version cache that already holds the
# commit must not hide the gap.
jq -n --arg oid "$(cat "$work/old-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"
squash="$work/src-squash"
git init --quiet -b main "$squash"
commit "$squash" 9.9.9 >"$work/squash-seed"
rm -rf "$work/lastgit-withart.git"
git clone --quiet --bare "$squash" "$work/lastgit-withart.git"
# Warm the cache through the Forgejo copy first.
run_set "$work/auto.json" "$helper_bin:$PATH" --source-venue forge || { cat "$work/auto.json.stderr" >&2; fail "cache warm run failed"; }
run_set "$work/auto.json" "$helper_bin:$PATH" || { cat "$work/auto.json.stderr" >&2; fail "squash run failed"; }
[ "$(jq -r .apps.withart.sha "$work/auto.json")" = "$(cat "$work/old-withart")" ] || fail "squash: pin moved"
[ "$(jq -r .apps.withart.source "$work/auto.json")" = "$work/forge-withart.git" ] || fail "squash: no fallback to the copy that has the commit"
[ "$(jq -r .apps.withart.source_venue "$work/auto.json")" = forge ] || fail "squash: venue"
[ "$(jq -r .apps.withart.source_fallback_from "$work/auto.json")" = lastgit ] || fail "squash: fallback not recorded"
[ "$(jq -r .apps.withart.source_reachable "$work/auto.json")" = true ] || fail "squash: reachable"
grep -q 'NOTE withart' "$work/auto.json.stderr" || fail "squash: fallback was silent"
# Put the full-history LastGit copy and the new artifact head back.
rm -rf "$work/lastgit-withart.git"
git clone --quiet --bare "$work/src-withart" "$work/lastgit-withart.git"
jq -n --arg oid "$(cat "$work/new-withart")" '{source_oid: $oid}' >"$work/artifacts/channels/withart/stable.json"

# --- 2. forge venue: the frozen copy ----------------------------------------
run_set "$work/forge.json" "$helper_bin:$PATH" --source-venue forge || { cat "$work/forge.json.stderr" >&2; fail "forge run failed"; }
[ "$(jq -r .apps.noart.sha "$work/forge.json")" = "$(cat "$work/old-noart")" ] || fail "forge venue did not read the frozen main"
[ "$(jq -r .apps.noart.sha_source "$work/forge.json")" = forge-main ] || fail "forge sha_source"
[ "$(jq -r .apps.withart.source_reachable "$work/forge.json")" = false ] || fail "frozen copy claimed the artifact head"
grep -q 'WARNING withart' "$work/forge.json.stderr" || fail "no warning for an unreachable pin: $(cat "$work/forge.json.stderr")"

# --- 3. auto without the helper: fallback, loudly ---------------------------
nohelper="$work/nohelper-bin"
mkdir -p "$nohelper"
for tool in git python3 bash; do ln -s "$(command -v "$tool")" "$nohelper/$tool"; done
run_set "$work/nohelper.json" "$nohelper:/usr/bin:/bin" || { cat "$work/nohelper.json.stderr" >&2; fail "no-helper run failed"; }
[ "$(jq -r .apps.noart.source_venue "$work/nohelper.json")" = forge ] || fail "no-helper venue"
grep -q 'git-remote-lastdb is not on PATH' "$work/nohelper.json.stderr" || fail "no-helper fallback was silent"

# --source-venue lastgit refuses without the helper.
if run_set "$work/strict.json" "$nohelper:/usr/bin:/bin" --source-venue lastgit; then
  fail "--source-venue lastgit ran without git-remote-lastdb"
fi

echo "PASS last-stack-canary-candidate-set"
