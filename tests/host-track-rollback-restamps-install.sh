#!/usr/bin/env bash
# A rollback must leave the install stamp describing the tree that is LIVE, and
# `status` must read the installed digest from the `current` symlink rather than
# from the stamp.
#
# Measured 2026-09-26 on the real host: the post-flip RED rollback moved current
# off 03ba4bd169a2 at 04:32:15Z and left the 04:30:35Z install stamp in place.
# `host_head` then named that digest's source oid for 45 minutes while two
# merged fixes were absent from the tree on PATH, and because `stale` is derived
# from the stamped digest, nothing advanced the install.
set -euo pipefail

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
export HOST_TRACK_SOAK_FILE_CARD=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) shift 2 ;;
    --channel) shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
cat "$root/channels/demo/stable.json"
SH
chmod +x "$tmp/bin/lastgit"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {"install_mode": "artifact", "artifact_channel": "stable"},
  "apps": [{
    "app": "demo",
    "kind": "artifact-bundle",
    "command": "demo",
    "artifact_root": "$HOME/../cas",
    "install_root": "$HOME/apps/demo",
    "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
    "safe_upgrade": {
      "soak_hours": 1,
      "post_flip_ticks": 2,
      "probes": [{"argv": ["bin/demo"], "timeout_s": 10}]
    }
  }]
}
JSON

publish_fixture() {
  local digest="$1" oid="$2" content="$3" payload sha size blob manifest
  payload="$tmp/payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/demo" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-07-21T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/demo/stable.json"
}

status_field() {
  "$ROOT/bin/host-track" status --json demo | jq -r --arg f "$1" '.[$f] | tostring'
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"

# v2 is green until the marker exists, so the install probe flips it and the
# post-flip probe then rejects the identical bytes. Using a marker keeps the
# digest stable; rewriting the payload would fail hash verification instead.
publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "first install should activate: $(demo)"

publish_fixture "$digest_two" "$oid_two" \
  $'#!/usr/bin/env bash\n[ -e "$HOME/red" ] && exit 1\necho v2'
"$ROOT/bin/host-track" refresh demo >/dev/null
[ "$(readlink "$HOME/apps/demo/canary")" = "versions/$digest_two" ] \
  || fail "v2 should be parked as canary"

jq '.started_epoch = 0' "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/soak.json"
mv "$tmp/soak.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
"$ROOT/bin/host-track" soak-watch demo >/dev/null
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_two" ] \
  || fail "soak should have activated v2: $(readlink "$HOME/apps/demo/current")"
[ "$(jq -r .manifest_digest "$HOST_TRACK_STAMP_DIR/demo.json")" = "$digest_two" ] \
  || fail "activation should stamp v2"
[ -f "$HOST_TRACK_STAMP_DIR/demo.postflip.json" ] \
  || fail "activation should leave a post-flip watch armed"
[ "$(jq -r .ticks_left "$HOST_TRACK_STAMP_DIR/demo.postflip.json")" = 1 ] \
  || fail "one green post-flip tick should have been consumed"

# ---- the rollback ----
touch "$HOME/red"
"$ROOT/bin/host-track" soak-watch demo >/dev/null 2>&1 || true
rm -f "$HOME/red"

[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_one" ] \
  || fail "post-flip RED should roll current back to v1: $(readlink "$HOME/apps/demo/current")"

# Half A: the write path. The stamp must describe v1, the tree that is live.
[ "$(jq -r .manifest_digest "$HOST_TRACK_STAMP_DIR/demo.json")" = "$digest_one" ] \
  || fail "rollback left the stamp naming the RED digest: $(jq -r .manifest_digest "$HOST_TRACK_STAMP_DIR/demo.json")"
[ "$(jq -r .source_oid "$HOST_TRACK_STAMP_DIR/demo.json")" = "$oid_one" ] \
  || fail "rollback left the stamp naming the RED source oid"
jq -e 'has("rolled_back_at")' "$HOST_TRACK_STAMP_DIR/demo.json" >/dev/null \
  || fail "a restamp after a rollback must be distinguishable from an install"

# Half B: the read path agrees, and reports no divergence.
[ "$(status_field host_head)" = "$oid_one" ] \
  || fail "status host_head should name the live tree: $(status_field host_head)"
[ "$(status_field manifest_digest)" = "$digest_one" ] \
  || fail "status manifest_digest should be the live digest"
[ "$(status_field stamp_diverged)" = false ] \
  || fail "a restamped rollback must not report divergence"

# ---- half B on its own: any writer that moves current without restamping ----
# The guard has to hold for a writer this file does not know about, so desync
# the stamp by hand and require `status` to follow the symlink.
jq --arg d "$digest_two" --arg o "$oid_two" \
  '.manifest_digest = $d | .source_oid = $o' "$HOST_TRACK_STAMP_DIR/demo.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.json"

[ "$(status_field manifest_digest)" = "$digest_one" ] \
  || fail "status read the installed digest from the stamp, not from current"
[ "$(status_field host_head)" = "$oid_one" ] \
  || fail "status read host_head from the stamp, not from current"
[ "$(status_field stamp_manifest_digest)" = "$digest_two" ] \
  || fail "status must still report what the stamp claims"
[ "$(status_field stamp_diverged)" = true ] \
  || fail "status must report the stamp/current divergence"
# This is the harm the divergence caused: the channel is on v2 and the live tree
# is v1, so a stamp-derived freshness reads fresh and no refresh ever advances.
[ "$(status_field stale)" = true ] \
  || fail "a host whose live tree is behind the channel must read stale"

printf 'ok: host-track rollback restamps install and status follows current\n'
