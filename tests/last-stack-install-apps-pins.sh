#!/usr/bin/env bash
# last-stack-install-apps installs the proved pair, not main:
#   1. --pins <candidate set>: every app lands at exactly the pinned commit,
#      from the pinned source, and an existing clone is moved, not re-cloned.
#   2. install-by-proof through a fake `lastdb app resolve`: the resolved commit
#      wins; a node with no proved row fails closed unless --allow-unproved.
#   3. a `lastdb` without `app resolve` falls back to main and says so.
# Hermetic: local bare repos stand in for GitHub; --source-only skips bun/npm.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-install-apps"
work="$(mktemp -d "${TMPDIR:-/tmp}/install-apps-pins.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

APPS=(brain kanban situations routines dogfood-graph org lastsecrets search lastdb-browser)
# bash 3.2 on the host lane has no associative arrays: one file per value.
first() { cat "$work/first-$1"; }
second() { cat "$work/second-$1"; }
for app in "${APPS[@]}"; do
  src="$work/src-$app"
  git init --quiet -b main "$src"
  git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m one
  git -C "$src" rev-parse HEAD >"$work/first-$app"
  git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m two
  git -C "$src" rev-parse HEAD >"$work/second-$app"
  git clone --quiet --bare "$src" "$work/$app.git"
done

# Candidate set pinning every app to its FIRST commit.
{
  printf '{"created_at":"2026-09-20T00:00:00Z","lastdb":{"build":"0.23.3-100-gaaaaaaaaa"},"apps":{'
  sep=""
  for app in "${APPS[@]}"; do
    printf '%s"%s":{"sha":"%s","app_version":"1.0.0","source":"%s","install_name":"%s"}' \
      "$sep" "$app" "$(first "$app")" "$work/$app.git" "$app"
    sep=","
  done
  printf '}}\n'
} >"$work/cset.json"

export HOME="$work/home"
mkdir -p "$HOME"
apps_dir="$work/apps"

# --- 1. pins ---------------------------------------------------------------
"$BIN" --no-brew --source-only --pins "$work/cset.json" --dir "$apps_dir" >"$work/pins.out" 2>&1 || {
  cat "$work/pins.out" >&2; fail "pinned install failed"; }
for app in "${APPS[@]}"; do
  [ "$(git -C "$apps_dir/$app" rev-parse HEAD)" = "$(first "$app")" ] || fail "$app not at the pinned commit"
done
[ "$(jq -r .mode "$apps_dir/.lastdb-app-receipts/brain.json")" = pinned ] || fail "receipt mode"

# Move the pin to SECOND for brain; the existing clone must move in place.
jq --arg sha "$(second brain)" '.apps.brain.sha = $sha' "$work/cset.json" >"$work/cset2.json"
"$BIN" --no-brew --source-only --pins "$work/cset2.json" --dir "$apps_dir" >"$work/pins2.out" 2>&1 || {
  cat "$work/pins2.out" >&2; fail "re-pin failed"; }
[ "$(git -C "$apps_dir/brain" rev-parse HEAD)" = "$(second brain)" ] || fail "brain did not move to the new pin"
[ "$(git -C "$apps_dir/kanban" rev-parse HEAD)" = "$(first kanban)" ] || fail "kanban moved without a pin change"

# --- 2. install by proof through a fake lastdb ------------------------------
fake_bin="$work/fakebin"
mkdir -p "$fake_bin"
cat >"$fake_bin/lastdb" <<EOF
#!/usr/bin/env bash
# Fake: \`lastdb app resolve <app> --channel <c> --json\` answers from a table.
[ "\$1" = app ] && [ "\$2" = resolve ] || { echo "unknown" >&2; exit 2; }
app="\$3"
if [ "\$app" = "--help" ]; then echo "usage"; exit 0; fi
table="$work/resolve-table.json"
row="\$(jq -c --arg a "\$app" '.[\$a] // empty' "\$table")"
if [ -z "\$row" ]; then
  echo "error: no stable row for app '\$app' was proved with lastdb 0.23.3-100-gaaaaaaaaa; run \\\`brew upgrade lastdb\\\`" >&2
  exit 1
fi
printf '%s\n' "\$row"
EOF
chmod +x "$fake_bin/lastdb"
{
  printf '{'
  sep=""
  for app in "${APPS[@]}"; do
    printf '%s"%s":{"app_id":"%s","channel":"stable","source":"%s","lastdb_version":"0.23.3-100-gaaaaaaaaa","lastdb_version_source":"flag","app_version":"1.1.0","sha":"%s","proved_at":"2026-09-20T00:00:00Z","proof_run":"run-x","index":"test","trust":"flag"}' \
      "$sep" "$app" "$app" "$work/$app.git" "$(second "$app")"
    sep=","
  done
  printf '}\n'
} >"$work/resolve-table.json"

proved_dir="$work/apps-proved"
PATH="$fake_bin:$PATH" "$BIN" --no-brew --source-only --dir "$proved_dir" >"$work/proved.out" 2>&1 || {
  cat "$work/proved.out" >&2; fail "install by proof failed"; }
for app in "${APPS[@]}"; do
  [ "$(git -C "$proved_dir/$app" rev-parse HEAD)" = "$(second "$app")" ] || fail "$app not at the proved commit"
done
[ "$(jq -r .mode "$proved_dir/.lastdb-app-receipts/search.json")" = proved ] || fail "proved receipt mode"
[ "$(jq -r .proof_run "$proved_dir/.lastdb-app-receipts/search.json")" = run-x ] || fail "proved receipt lacks proof_run"

# No proved row for `search` → fail closed; --allow-unproved falls back to main.
jq 'del(.search)' "$work/resolve-table.json" >"$work/t2.json" && mv "$work/t2.json" "$work/resolve-table.json"
closed_dir="$work/apps-closed"
if PATH="$fake_bin:$PATH" "$BIN" --no-brew --source-only --dir "$closed_dir" >"$work/closed.out" 2>&1; then
  cat "$work/closed.out" >&2; fail "missing proved row did not fail closed"
fi
grep -q "no stable row for search" "$work/closed.out" || fail "fail-closed message missing: $(tail -3 "$work/closed.out")"
[ ! -d "$closed_dir/search" ] || fail "search was installed without a proved row"

# The fallback clones GitHub, which this test cannot reach; point the legacy
# URL at the local bare repo through the pins-less path by seeding the clone.
git clone --quiet "$work/search.git" "$closed_dir/search"
git -C "$closed_dir/search" checkout --quiet --detach "$(first search)"
git -C "$closed_dir/search" checkout --quiet main
PATH="$fake_bin:$PATH" "$BIN" --no-brew --source-only --dir "$closed_dir" --allow-unproved >"$work/unproved.out" 2>&1 || {
  cat "$work/unproved.out" >&2; fail "--allow-unproved failed"; }
grep -q "WITHOUT a proved row" "$work/unproved.out" || fail "unproved warning missing"
[ "$(jq -r .mode "$closed_dir/.lastdb-app-receipts/search.json")" = unproved-main ] || fail "unproved receipt mode"

# --- 3. an old lastdb without `app resolve` says so and continues ------------
old_bin="$work/oldbin"
mkdir -p "$old_bin"
printf '#!/usr/bin/env bash\necho "error: unrecognized subcommand" >&2\nexit 2\n' >"$old_bin/lastdb"
chmod +x "$old_bin/lastdb"
legacy_dir="$work/apps-legacy"
mkdir -p "$legacy_dir"
for app in "${APPS[@]}"; do git clone --quiet "$work/$app.git" "$legacy_dir/$app"; done
PATH="$old_bin:$PATH" "$BIN" --no-brew --source-only --dir "$legacy_dir" >"$work/legacy.out" 2>&1 || {
  cat "$work/legacy.out" >&2; fail "legacy path failed"; }
grep -q 'has no `app resolve`' "$work/legacy.out" || fail "legacy note missing"
[ "$(jq -r .mode "$legacy_dir/.lastdb-app-receipts/brain.json")" = unproved-main ] || fail "legacy receipt mode"

# --- 4. one broken pin does not cost the other apps their install ------------
# Regression: papercut-canary-primary-rows-smoke-red-0-23-3-2375-ga7bac36f1.
# routines (4th in install order) pinned a commit its source did not have, the
# installer exited at once, and the 5 apps after it had no receipt at all.
bad_sha="0123456789abcdef0123456789abcdef01234567"
jq --arg sha "$bad_sha" '.apps.routines.sha = $sha' "$work/cset.json" >"$work/cset-broken.json"
broken_dir="$work/apps-broken"
if "$BIN" --no-brew --source-only --pins "$work/cset-broken.json" --dir "$broken_dir" >"$work/broken.out" 2>&1; then
  cat "$work/broken.out" >&2; fail "a broken pin exited 0"
fi
for app in "${APPS[@]}"; do
  [ "$app" = routines ] && continue
  [ "$(git -C "$broken_dir/$app" rev-parse HEAD 2>/dev/null)" = "$(first "$app")" ] \
    || { cat "$work/broken.out" >&2; fail "$app was not installed after routines failed"; }
  [ "$(jq -r .mode "$broken_dir/.lastdb-app-receipts/$app.json" 2>/dev/null)" = pinned ] \
    || fail "$app has no pinned receipt after routines failed"
done
[ "$(jq -r .mode "$broken_dir/.lastdb-app-receipts/routines.json")" = failed ] || fail "routines receipt is not failed"
[ "$(jq -r .stage "$broken_dir/.lastdb-app-receipts/routines.json")" = source ] || fail "routines receipt stage"
[ "$(jq -r .sha "$broken_dir/.lastdb-app-receipts/routines.json")" = "$bad_sha" ] || fail "routines receipt sha"
grep -q 'FAILED routines (stage: source)' "$work/broken.out" || fail "summary does not name routines: $(tail -5 "$work/broken.out")"
grep -q '1 of 9 apps FAILED' "$work/broken.out" || fail "summary count missing: $(tail -5 "$work/broken.out")"

# A failed rerun must overwrite an earlier good receipt, never leave it.
jq --arg sha "$bad_sha" '.apps.brain.sha = $sha' "$work/cset.json" >"$work/cset-brain-broken.json"
"$BIN" --no-brew --source-only --pins "$work/cset-brain-broken.json" --dir "$apps_dir" >"$work/rerun.out" 2>&1 \
  && fail "a broken brain pin exited 0"
[ "$(jq -r .mode "$apps_dir/.lastdb-app-receipts/brain.json")" = failed ] || fail "stale pinned receipt survived a failed rerun"

# --- 5. the pinned source wins over the clone's old origin -------------------
# LastGit era 3 froze each app's Forgejo copy. A clone made from the frozen
# copy must follow the candidate set's new source, not keep fetching the old
# origin that will never have the commit.
frozen="$work/frozen-search.git"
git clone --quiet --bare "$work/src-search" "$frozen"
git -C "$frozen" update-ref refs/heads/main "$(first search)"
git -C "$frozen" reflog expire --expire=now --all 2>/dev/null || true
git -C "$frozen" gc --quiet --prune=now 2>/dev/null || true
moved_dir="$work/apps-moved"
mkdir -p "$moved_dir"
git clone --quiet "$frozen" "$moved_dir/search"
if git -C "$moved_dir/search" cat-file -e "$(second search)^{commit}" 2>/dev/null; then
  fail "fixture: the frozen clone already has the newer commit"
fi
jq --arg sha "$(second search)" --arg src "$work/search.git" \
  '.apps = {search: (.apps.search + {sha: $sha, source: $src})}' "$work/cset.json" >"$work/cset-moved.json"
"$BIN" --no-brew --source-only --pins "$work/cset-moved.json" --dir "$moved_dir" >"$work/moved.out" 2>&1 || true
[ "$(git -C "$moved_dir/search" rev-parse HEAD)" = "$(second search)" ] \
  || { cat "$work/moved.out" >&2; fail "existing clone did not follow the pinned source"; }
[ "$(git -C "$moved_dir/search" remote get-url origin)" = "$work/search.git" ] || fail "origin was not moved to the pinned source"

# --- 6. lastdb:// (LastGit) sources ------------------------------------------
# The candidate set names lastdb:///<repo> since era 3. git reaches it through
# the git-remote-lastdb helper; without the helper the app fails by name and
# the rest still install. With it, the pinned commit installs from LastGit.
# An insteadOf rewrite stands the local bare repo in for the LastGit remote.
nohelper="$work/nohelper-bin"
mkdir -p "$nohelper"
for tool in git jq; do ln -s "$(command -v "$tool")" "$nohelper/$tool"; done
jq '.apps.routines.source = "lastdb:///routines"' "$work/cset.json" >"$work/cset-lastgit.json"
lg_dir="$work/apps-lastgit-nohelper"
if PATH="$nohelper:/usr/bin:/bin" "$BIN" --no-brew --source-only --pins "$work/cset-lastgit.json" --dir "$lg_dir" \
  >"$work/lg-nohelper.out" 2>&1; then
  fail "a lastdb:// source without git-remote-lastdb exited 0"
fi
grep -q 'git-remote-lastdb is not on PATH' "$work/lg-nohelper.out" || fail "missing-helper message: $(tail -5 "$work/lg-nohelper.out")"
[ "$(jq -r .mode "$lg_dir/.lastdb-app-receipts/search.json")" = pinned ] || fail "search did not install next to a lastdb:// failure"

helper_bin="$work/helper-bin"
mkdir -p "$helper_bin"
printf '#!/bin/sh\necho "fixture helper must not run (insteadOf rewrites the URL)" >&2\nexit 1\n' >"$helper_bin/git-remote-lastdb"
chmod +x "$helper_bin/git-remote-lastdb"
lg_ok="$work/apps-lastgit"
PATH="$helper_bin:$PATH" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="url.$work/routines.git.insteadOf" GIT_CONFIG_VALUE_0="lastdb:///routines" \
  "$BIN" --no-brew --source-only --pins "$work/cset-lastgit.json" --dir "$lg_ok" >"$work/lg.out" 2>&1 || {
    cat "$work/lg.out" >&2; fail "lastdb:// pinned install failed"; }
[ "$(git -C "$lg_ok/routines" rev-parse HEAD)" = "$(first routines)" ] || fail "routines not at the LastGit pin"
[ "$(jq -r .source "$lg_ok/.lastdb-app-receipts/routines.json")" = "lastdb:///routines" ] || fail "receipt does not name the LastGit source"

echo "PASS last-stack-install-apps-pins"
