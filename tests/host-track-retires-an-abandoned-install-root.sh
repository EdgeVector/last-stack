#!/usr/bin/env bash
set -euo pipefail

# `INSTALL_ROOT_DEFAULT/<app>` is the install root for most apps, so every
# standing instruction for proving a merge installed greps
# `~/.host-track/apps/<app>/current`. An app that declares its own
# `install_root` moved away from that path, and the move left the old tree in
# place -- complete, plausible, resolvable, and a month stale. Measured
# 2026-10-02 and 2026-10-03 on `last-stack`: 1 of 17 apps, and the one app
# whose tools every agent greps. The uniform check then reports a delivered fix
# as undelivered, and because that grep is the advice written down precisely
# BECAUSE the status stamp has lied before, the more careful the reader is, the
# more confidently it is wrong.
# (papercut-host-track-apps-last-stack-current-is-a-33-day-stale-decoy-tree-after-the-artifact-migration-20261002)
#
# The load-bearing case here is `stayed`: for 13 of the 17 apps the legacy path
# IS the live install root, so a retire that keyed on anything looser than
# "install_root resolves somewhere else" would delete the fleet's installs.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_INSTALL_ROOT="$tmp/home/legacy-apps"
export HOST_TRACK_SOAK_FILE_CARD=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
manifest="$root/channels/$app/$channel.json"
[ -f "$manifest" ] || exit 3
cat "$manifest"
SH
chmod +x "$tmp/bin/lastgit"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable"
  },
  "apps": [
    {
      "app": "moved",
      "kind": "artifact-bundle",
      "command": "moved",
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/elsewhere/moved",
      "links": [{"source": "bin/moved", "target": "$HOME/.local/bin/moved"}],
      "notes": "declares its own install_root; the legacy default is a leftover"
    },
    {
      "app": "stayed",
      "kind": "artifact-bundle",
      "command": "stayed",
      "artifact_root": "$HOME/../cas",
      "links": [{"source": "bin/stayed", "target": "$HOME/.local/bin/stayed"}],
      "notes": "no install_root; the legacy default IS the live install root"
    }
  ]
}
JSON

publish() {
  local app="$1" body="$2" digest oid tree files rel sha size blob
  digest="$(printf '%s' "$app-$body" | shasum -a 256 | awk '{print $1}')"
  oid="$(printf '%s' "$app" | shasum -a 1 | awk '{print $1}')"
  tree="$tmp/tree-$app"
  rm -rf "$tree"
  mkdir -p "$tree/bin"
  printf '#!/usr/bin/env bash\necho %s\n' "$body" > "$tree/bin/$app"
  chmod +x "$tree/bin/$app"
  files="[]"
  while IFS= read -r rel; do
    sha="$(shasum -a 256 "$tree/$rel" | awk '{print $1}')"
    size="$(wc -c < "$tree/$rel" | tr -d ' ')"
    blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
    mkdir -p "$(dirname "$blob")"
    cp "$tree/$rel" "$blob"
    files="$(printf '%s' "$files" | jq -c --arg path "$rel" --arg sha "$sha" --argjson size "$size" \
      '. + [{path: $path, sha256: $sha, size: $size, mode: 493}]')"
  done < <(cd "$tree" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  mkdir -p "$tmp/cas/channels/$app" "$tmp/cas/manifests"
  jq -n --arg app "$app" --arg digest "$digest" --arg oid "$oid" --argjson files "$files" \
    '{schema_version: 1, app: $app, repo: ("EdgeVector/" + $app), source_oid: $oid,
      platform: "test-arm64", created_at: "2026-10-03T00:00:00Z",
      files: $files, manifest_digest: $digest}' > "$tmp/cas/manifests/$digest.json"
  cp "$tmp/cas/manifests/$digest.json" "$tmp/cas/channels/$app/stable.json"
}

publish moved moved-v1
publish stayed stayed-v1
"$ROOT/bin/host-track" install moved >/dev/null
"$ROOT/bin/host-track" install stayed >/dev/null
[ "$(moved)" = "moved-v1" ] || fail "moved did not install"
[ "$(stayed)" = "stayed-v1" ] || fail "stayed did not install"

legacy_moved="$HOST_TRACK_INSTALL_ROOT/moved"
legacy_stayed="$HOST_TRACK_INSTALL_ROOT/stayed"

# `stayed` installs INTO the legacy default; that is the live root, not a decoy.
[ -L "$legacy_stayed/current" ] || fail "fixture wrong: stayed should install into the default root"
# `moved` installs elsewhere, so nothing should exist at the default root yet.
[ ! -e "$legacy_moved" ] || fail "fixture wrong: moved should not use the default root"

# ── Case 1: no leftover, nothing to say and nothing to do ───────────────────
"$ROOT/bin/host-track" check moved >"$tmp/clean.out" 2>"$tmp/clean.err" \
  || fail "clean install failed check: $(cat "$tmp/clean.err")"
grep -q 'abandoned install root' "$tmp/clean.err" \
  && fail "reported an abandoned root that does not exist: $(cat "$tmp/clean.err")"

# ── Build the leftover the migration left behind ────────────────────────────
# A complete, plausible, resolvable tree -- exactly what was measured.
mkdir -p "$legacy_moved/versions/staledigest/bin"
printf '#!/usr/bin/env bash\necho moved-PRE-MIGRATION\n' \
  > "$legacy_moved/versions/staledigest/bin/moved"
chmod +x "$legacy_moved/versions/staledigest/bin/moved"
ln -s versions/staledigest "$legacy_moved/current"
ln -s versions/staledigest "$legacy_moved/previous"
[ "$("$legacy_moved/current/bin/moved")" = "moved-PRE-MIGRATION" ] \
  || fail "fixture wrong: the leftover must answer reads"

# ── Case 2: check REPORTS it and does not fail ──────────────────────────────
"$ROOT/bin/host-track" check moved >"$tmp/decoy.out" 2>"$tmp/decoy.err" \
  || fail "an abandoned root must not fail check (the app is healthy; the leftover is the liar)"
grep -q "moved has an abandoned install root at $legacy_moved that still resolves" "$tmp/decoy.err" \
  || fail "check did not name the abandoned root (got: $(cat "$tmp/decoy.err"))"
grep -q 'it is NOT what runs' "$tmp/decoy.err" \
  || fail "check did not say the leftover is not what runs (got: $(cat "$tmp/decoy.err"))"

# ── Case 3: check never reports the app whose live root IS the default ──────
"$ROOT/bin/host-track" check stayed >"$tmp/stayed.out" 2>"$tmp/stayed.err" \
  || fail "stayed failed check: $(cat "$tmp/stayed.err")"
grep -q 'abandoned install root' "$tmp/stayed.err" \
  && fail "reported the LIVE install root as abandoned: $(cat "$tmp/stayed.err")"

# ── Case 4: refresh retires it, preserves the bytes, leaves a breadcrumb ────
"$ROOT/bin/host-track" refresh moved >"$tmp/ret.out" 2>"$tmp/ret.err" || true
[ ! -e "$legacy_moved" ] \
  || fail "refresh left the abandoned root in place: $(cat "$tmp/ret.err")"
[ ! -e "$legacy_moved/current" ] \
  || fail "the abandoned path still answers a read"
grep -q "moved retired abandoned install root $legacy_moved" "$tmp/ret.err" \
  || fail "refresh did not report the retire (got: $(cat "$tmp/ret.err"))"
relocated="$(find "$HOST_TRACK_INSTALL_ROOT/.relocated" -maxdepth 1 -name 'moved-*' -type d | head -1)"
[ -n "$relocated" ] || fail "retire deleted the tree instead of moving it aside"
[ "$("$relocated/current/bin/moved")" = "moved-PRE-MIGRATION" ] \
  || fail "the relocated tree is not intact"
[ -f "$legacy_moved.relocated" ] || fail "retire left no breadcrumb"
grep -q "$relocated" "$legacy_moved.relocated" \
  || fail "the breadcrumb does not name where the tree went"
grep -q 'host-track status moved' "$legacy_moved.relocated" \
  || fail "the breadcrumb does not say where to read what actually runs"

# The live install is untouched by all of this.
[ "$(moved)" = "moved-v1" ] || fail "retiring the leftover disturbed the live install"

# ── Case 5: THE LOAD-BEARING ONE ────────────────────────────────────────────
# 13 of the 17 apps on this host install INTO the legacy default. A retire that
# keyed on anything looser than "install_root resolves somewhere else" would
# delete their installs. Refresh `stayed` and prove nothing moved.
stayed_target="$(readlink "$legacy_stayed/current")"
"$ROOT/bin/host-track" refresh stayed >"$tmp/keep.out" 2>"$tmp/keep.err" || true
[ -L "$legacy_stayed/current" ] \
  || fail "refresh RETIRED THE LIVE INSTALL ROOT of an app that installs into the default"
[ "$(readlink "$legacy_stayed/current")" = "$stayed_target" ] \
  || fail "refresh moved the live current pointer of an app installed in the default root"
[ "$(stayed)" = "stayed-v1" ] || fail "refresh broke the app installed in the default root"
[ ! -e "$HOST_TRACK_INSTALL_ROOT/.relocated/stayed-"* ] 2>/dev/null \
  || fail "refresh relocated the live install root"
grep -q 'abandoned install root' "$tmp/keep.err" \
  && fail "refresh called the live install root abandoned: $(cat "$tmp/keep.err")"

# ── Case 6: a leftover directory that answers no read is not a decoy ────────
# `versions/` alone misleads nobody: the standing instruction greps `current`,
# and a reader who has a digest got it from the stamp, which names the live one.
mkdir -p "$legacy_moved/versions/orphan/bin"
"$ROOT/bin/host-track" check moved >"$tmp/bare.out" 2>"$tmp/bare.err" \
  || fail "a bare leftover dir must not fail check"
grep -q 'abandoned install root' "$tmp/bare.err" \
  && fail "reported a leftover that answers no read: $(cat "$tmp/bare.err")"
"$ROOT/bin/host-track" refresh moved >/dev/null 2>&1 || true
[ -d "$legacy_moved/versions/orphan" ] \
  || fail "retired a leftover dir that answers no read"

printf 'ok: an abandoned install root is reported, retired aside, and never confused with a live one\n'
