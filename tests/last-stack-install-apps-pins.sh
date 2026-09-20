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

echo "PASS last-stack-install-apps-pins"
