#!/usr/bin/env bash
# Safe upgrade is a canary soak: refresh parks canary, soak-watch promotes.
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

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"

publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "first install should activate (no current to soak against)"

publish_fixture "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho v2'
"$ROOT/bin/host-track" refresh demo >/dev/null
[ "$(demo)" = v1 ] || fail "refresh with soak_hours parked canary but flipped PATH: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_one" ] \
  || fail "current should stay on v1 during soak"
[ "$(readlink "$HOME/apps/demo/canary")" = "versions/$digest_two" ] \
  || fail "canary should point at v2"
[ -f "$HOST_TRACK_STAMP_DIR/demo.soak.json" ] || fail "soak stamp missing"
jq -e '.status == "soaking"' "$HOST_TRACK_STAMP_DIR/demo.soak.json" >/dev/null \
  || fail "soak stamp not soaking"

out="$("$ROOT/bin/host-track" soak-watch demo)"
printf '%s\n' "$out" | grep -q 'soak pending' || fail "early soak-watch should be pending: $out"
[ "$(demo)" = v1 ] || fail "pending soak flipped live: $(demo)"

jq '.started_epoch = 0' "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
"$ROOT/bin/host-track" soak-watch demo >/dev/null
[ "$(demo)" = v2 ] || fail "soak-watch did not promote after window: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_two" ] \
  || fail "current should be v2 after soak promote"

printf 'ok: host-track canary soak\n'
