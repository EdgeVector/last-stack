#!/usr/bin/env bash
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
cat "$root/channels/$app/$channel.json"
SH
chmod +x "$tmp/bin/lastgit"

publish_fixture() {
  local app="$1" digest="$2" oid="$3" content="$4"
  local payload sha size blob manifest
  payload="$tmp/payload-$app"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/$app" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg app "$app" --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: $app, repo: ("EdgeVector/" + $app), source_oid: $oid,
      platform: "test-arm64", created_at: "2026-07-22T00:00:00Z",
      files: [{path: ("bin/" + $app), sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/$app/stable.json"
}

publish_lastdb_bundle() {
  local digest="$1" oid="$2"
  local payload_lastdb payload_lastdbd sha_lastdb sha_lastdbd size_lastdb size_lastdbd blob_lastdb blob_lastdbd manifest
  payload_lastdb="$tmp/payload-lastdb"
  payload_lastdbd="$tmp/payload-lastdbd"
  printf '#!/usr/bin/env bash\necho lastdb\n' > "$payload_lastdb"
  printf '#!/usr/bin/env bash\necho lastdbd\n' > "$payload_lastdbd"
  sha_lastdb="$(shasum -a 256 "$payload_lastdb" | awk '{print $1}')"
  sha_lastdbd="$(shasum -a 256 "$payload_lastdbd" | awk '{print $1}')"
  size_lastdb="$(wc -c < "$payload_lastdb" | tr -d ' ')"
  size_lastdbd="$(wc -c < "$payload_lastdbd" | tr -d ' ')"
  blob_lastdb="$tmp/cas/blobs/sha256/${sha_lastdb:0:2}/$sha_lastdb"
  blob_lastdbd="$tmp/cas/blobs/sha256/${sha_lastdbd:0:2}/$sha_lastdbd"
  mkdir -p "$(dirname "$blob_lastdb")" "$(dirname "$blob_lastdbd")" "$tmp/cas/channels/lastdb-bundle" "$tmp/cas/manifests"
  cp "$payload_lastdb" "$blob_lastdb"
  cp "$payload_lastdbd" "$blob_lastdbd"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg digest "$digest" --arg oid "$oid" \
    --arg sha_lastdb "$sha_lastdb" --argjson size_lastdb "$size_lastdb" \
    --arg sha_lastdbd "$sha_lastdbd" --argjson size_lastdbd "$size_lastdbd" \
    '{schema_version: 1, app: "lastdb-bundle", repo: "EdgeVector/fold", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-07-22T00:00:00Z",
      files: [
        {path: "bin/lastdb", sha256: $sha_lastdb, size: $size_lastdb, mode: 493},
        {path: "bin/lastdbd", sha256: $sha_lastdbd, size: $size_lastdbd, mode: 493}
      ],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/lastdb-bundle/stable.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
digest_lastdb="$(printf 'd%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
oid_lastdb="$(printf '4%.0s' {1..40})"

publish_fixture demo "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho demo'
publish_fixture demo "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho previous'
publish_lastdb_bundle "$digest_lastdb" "$oid_lastdb"

cat > "$HOST_TRACK_REGISTRY" <<EOF
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "artifact_root": "$tmp/cas"
  },
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "artifact invariant fixture"
    },
    {
      "app": "legacy",
      "install_mode": "checkout",
      "kind": "checkout-shim",
      "command": "legacy",
      "host_track": "$HOME/legacy",
      "artifact_exemption": {
        "kind": "bootstrap-recovery",
        "owner": "platform",
        "rationale": "fixture remains checkout-backed until artifact producer exists"
      }
    },
    {
      "app": "localcli",
      "install_mode": "local-safe",
      "kind": "local-safe cli",
      "command": "localcli",
      "install_root": "$HOME/apps/localcli",
      "links": [{"source": "bin/localcli", "target": "$HOME/.local/bin/localcli"}],
      "notes": "local-safe invariant fixture"
    },
    {
      "app": "lastdb",
      "kind": "artifact-bundle",
      "command": "lastdb",
      "artifact_app": "lastdb-bundle",
      "install_root": "$HOME/apps/lastdb",
      "links": [{"source": "bin/lastdb", "target": "$HOME/.local/bin/lastdb"}]
    },
    {
      "app": "lastdbd",
      "kind": "artifact-bundle",
      "command": "lastdbd",
      "artifact_app": "lastdb-bundle",
      "install_root": "$HOME/apps/lastdbd",
      "links": [{"source": "bin/lastdbd", "target": "$HOME/.local/bin/lastdbd"}]
    }
  ]
}
EOF

cp "$tmp/cas/manifests/$digest_one.json" "$tmp/cas/channels/demo/stable.json"
"$ROOT/bin/host-track" install demo >/dev/null
cp "$tmp/cas/manifests/$digest_two.json" "$tmp/cas/channels/demo/stable.json"
"$ROOT/bin/host-track" install demo >/dev/null
cp "$tmp/cas/manifests/$digest_one.json" "$tmp/cas/channels/demo/stable.json"
"$ROOT/bin/host-track" rollback demo >/dev/null
cp "$tmp/cas/manifests/$digest_one.json" "$tmp/cas/channels/demo/stable.json"

"$ROOT/bin/host-track" install lastdb >/dev/null
"$ROOT/bin/host-track" install lastdbd >/dev/null

local_version="$(printf '5%.0s' {1..40})"
mkdir -p "$HOME/apps/localcli/versions/$local_version/bin"
printf '#!/usr/bin/env bash\necho localcli\n' > "$HOME/apps/localcli/versions/$local_version/bin/localcli"
chmod +x "$HOME/apps/localcli/versions/$local_version/bin/localcli"
ln -s "versions/$local_version" "$HOME/apps/localcli/current"
ln -s "$HOME/apps/localcli/current/bin/localcli" "$HOME/.local/bin/localcli"
jq -n \
  --arg version "$local_version" --arg root "$HOME/apps/localcli" \
  '{app:"localcli", install_mode:"local-safe", install_root:$root,
    version_id:$version, current:("versions/" + $version), previous:null,
    activated_at:"2026-07-22T00:00:00Z"}' \
  > "$HOST_TRACK_STAMP_DIR/localcli.json"

invariant_json="$("$ROOT/bin/last-stack-host-track-artifact-invariant" --json || true)"
printf '%s\n' "$invariant_json" | jq -e '
  .ok == true
  and any(.checks[]; .app == "demo" and .ok == true and (.message | test("previous version is restorable")))
  and any(.checks[]; .app == "legacy" and .ok == true and (.message | test("bootstrap-recovery")))
  and any(.checks[]; .app == "localcli" and .ok == true and (.message | test("local-safe current")))
' >/dev/null || {
  printf '%s\n' "$invariant_json" >&2
  fail "valid registry did not satisfy artifact invariant"
}

jq 'del(.apps[] | select(.app == "legacy").artifact_exemption)' "$HOST_TRACK_REGISTRY" > "$tmp/bad-registry.json"
if HOST_TRACK_REGISTRY="$tmp/bad-registry.json" "$ROOT/bin/last-stack-host-track-artifact-invariant" >/dev/null 2>&1; then
  fail "checkout app without exemption passed"
fi

printf 'tampered\n' > "$HOME/apps/demo/current/bin/demo"
if "$ROOT/bin/last-stack-host-track-artifact-invariant" >/dev/null 2>&1; then
  fail "tampered active artifact passed"
fi

printf 'ok: host-track artifact invariant\n'
