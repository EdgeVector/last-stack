#!/usr/bin/env bash
# host-track follows the registry `next` channel (North Star slice 7):
#   - the desired oid is the one `lastdb app resolve` proves, not the channel head
#   - a pinned oid whose artifact is published installs it; status reads pinned
#   - a newer channel head that is NOT proved does not make the host stale
#   - no proved row → the host HOLDS its current install (refresh returns 75)
#   - an app not on the index falls back to the channel head as before
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_PROBE_SKIP=1
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
oid_three="$(printf '3%.0s' {1..40})"
export HOST_TRACK_TEST_MAIN_OID="$oid_one"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = status ]; then
  jq -n --arg oid "$HOST_TRACK_TEST_MAIN_OID" '{refs:[{name:"refs/heads/main",oid:$oid}]}'; exit 0
fi
if [ "${1:-}" = ref ]; then
  printf '%s\t%s\t%s\n' "$HOST_TRACK_TEST_MAIN_OID" "refs/heads/${3:-main}" point; exit 0
fi
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;; --channel) channel="$2"; shift 2 ;; --root) root="$2"; shift 2 ;;
    --json|--promote) shift ;; --repo|--oid|--context|--manifest) shift 2 ;; *) exit 2 ;;
  esac
done
cat "$root/channels/$app/$channel.json"
SH
chmod +x "$tmp/bin/lastgit"

# Fake `lastdb app resolve`: answers from $tmp/resolve.json {app: sha}; an app
# absent from the table is "not in the index"; RESOLVE_NO_ROW=1 is "no row".
cat > "$tmp/bin/lastdb" <<SH
#!/usr/bin/env bash
[ "\$1" = app ] && [ "\$2" = resolve ] || { echo unknown >&2; exit 2; }
[ "\$3" = --help ] && { echo usage; exit 0; }
app="\$3"
echo "resolve \$*" >>"$tmp/resolve-calls.log"
if [ "\${RESOLVE_NO_ROW:-0}" = 1 ]; then
  echo "error: no next row for app '\$app' was proved with lastdb 0.23.3-1-gx; run \\\`brew upgrade lastdb\\\`" >&2; exit 1
fi
sha="\$(jq -r --arg a "\$app" '.[\$a] // empty' "$tmp/resolve.json")"
[ -n "\$sha" ] || { echo "error: app '\$app' is not in the next index" >&2; exit 1; }
jq -n --arg a "\$app" --arg sha "\$sha" '{app_id:\$a, channel:"next", sha:\$sha, app_version:"1.0.0", lastdb_version:"0.23.3-1-gx", proof_run:"run-x", source:"x"}'
SH
chmod +x "$tmp/bin/lastdb"
printf '{"demo":"%s"}\n' "$oid_one" >"$tmp/resolve.json"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "registry_channel": "next",
    "registry_index": "http://forge.test/registry"
  },
  "apps": [
    {
      "app": "demo", "kind": "artifact-bundle", "command": "demo", "install_mode": "artifact",
      "gate": "lastgit", "gate_main": "lastdb:///demo#main", "track_gate_main": false,
      "artifact_root": "$HOME/../cas", "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "registry pin fixture"
    },
    {
      "app": "plain", "kind": "artifact-bundle", "command": "plain", "install_mode": "artifact",
      "gate": "lastgit", "gate_main": "lastdb:///plain#main", "track_gate_main": false,
      "artifact_root": "$HOME/../cas", "install_root": "$HOME/apps/plain",
      "links": [{"source": "bin/plain", "target": "$HOME/.local/bin/plain"}],
      "notes": "not on the index; follows the channel head"
    }
  ]
}
JSON

publish_fixture() {
  local app="$1" digest="$2" oid="$3" content="$4" payload sha size blob manifest
  payload="$tmp/payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/$app" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n --arg app "$app" --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: $app, repo: $app, source_oid: $oid, platform: "test-arm64",
      created_at: "2026-09-20T00:00:00Z",
      files: [{path: ("bin/" + $app), sha256: $sha, size: $size, mode: 493}], manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/$app/stable.json"
}

d1="$(printf 'a%.0s' {1..64})"; d2="$(printf 'b%.0s' {1..64})"; d3="$(printf 'c%.0s' {1..64})"

# 1. Pinned install: channel head is oid_one, resolve says oid_one.
publish_fixture demo "$d1" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "pinned install did not run"
grep -q -- "--index http://forge.test/registry" "$tmp/resolve-calls.log" || fail "registry_index default not passed to resolve"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_channel == "next" and .registry_pin_state == "pinned" and .stale == false' >/dev/null \
  || fail "pinned status: $st"

# 2. Channel head moves to oid_two (published), but the proved row is still oid_one:
#    the host is NOT stale, and refresh keeps v1.
publish_fixture demo "$d2" "$oid_two" $'#!/usr/bin/env bash\necho v2'
export HOST_TRACK_TEST_MAIN_OID="$oid_two"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == false and .registry_pin_state == "pinned"' >/dev/null \
  || fail "unproved channel head made the host stale: $st"
"$ROOT/bin/host-track" refresh demo >/dev/null 2>&1 || true
[ "$(demo)" = v1 ] || fail "refresh moved to an unproved commit"

# 3. The proof lands for oid_two: now the host is stale and refresh installs v2.
printf '{"demo":"%s"}\n' "$oid_two" >"$tmp/resolve.json"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == true and .registry_pin_oid == "'"$oid_two"'"' >/dev/null \
  || fail "proved pin not stale: $st"
"$ROOT/bin/host-track" refresh demo >/dev/null 2>&1
[ "$(demo)" = v2 ] || fail "refresh did not install the proved commit"

# 4. Proved commit with no published artifact yet: hold (75), status pinned-unpublished.
printf '{"demo":"%s"}\n' "$oid_three" >"$tmp/resolve.json"
set +e
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/hold.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "unpublished pin did not hold (rc=$rc): $(cat "$tmp/hold.err")"
grep -q "no published artifact yet" "$tmp/hold.err" || fail "hold message: $(cat "$tmp/hold.err")"
[ "$(demo)" = v2 ] || fail "hold changed the install"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "pinned-unpublished"' >/dev/null || fail "pinned-unpublished status: $st"

# 5. No proved row at all for this node: hold, not stale.
set +e
RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/norow.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "no-row did not hold (rc=$rc): $(cat "$tmp/norow.err")"
grep -q "no registry row proved with this LastDB build" "$tmp/norow.err" || fail "no-row message: $(cat "$tmp/norow.err")"
st="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "no-proved-row" and .stale == false' >/dev/null || fail "no-row status: $st"

# 6. An app not on the index follows the channel head as before.
publish_fixture plain "$d3" "$oid_three" $'#!/usr/bin/env bash\necho p1'
"$ROOT/bin/host-track" install plain >/dev/null
[ "$(plain)" = p1 ] || fail "not-on-index app did not install from the channel"
st="$("$ROOT/bin/host-track" status --json plain)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "not-on-index" and .stale == false' >/dev/null || fail "not-on-index status: $st"

# 7. registry_follow=false opts an app out entirely.
jq '.apps[0].registry_follow = false' "$HOST_TRACK_REGISTRY" >"$tmp/r2.json" && mv "$tmp/r2.json" "$HOST_TRACK_REGISTRY"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_channel == null' >/dev/null || fail "registry_follow=false still pinned: $st"

printf 'PASS host-track-registry-pin\n'
