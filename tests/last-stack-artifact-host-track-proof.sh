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

default_registry="$ROOT/config/host-track/apps.json"

[ -x "$ROOT/bin/last-stack-artifact-host-track-proof" ] \
  || fail "artifact host-track proof helper is missing from bin"
jq -e '.artifacts[] | select(.app == "last-stack") | .paths | index("bin")' \
  "$ROOT/.lastgit/artifacts.json" >/dev/null \
  || fail "last-stack artifact bundle omits bin, including proof helper"

jq -e '
  . as $root
  | [$root.apps[] | select((.install_mode // $root.defaults.install_mode // "checkout") == "checkout")] | length == 0
' "$default_registry" >/dev/null || fail "default registry still has checkout-backed entries"

jq -e '
  def app($name): .apps[] | select(.app == $name);
  (app("lastgit") | .install_mode == "artifact" and .artifact_app == "lastgit" and (.links | length) >= 2)
  and (app("brain") | .install_mode == "artifact" and .artifact_app == "brain" and (.links | length) >= 2)
  and (app("situations") | .install_mode == "artifact" and .artifact_app == "situations" and (.links | length) == 2)
  and (app("kanban") | .install_mode == "artifact" and .artifact_app == "fkanban" and .install_root == "$HOME/.host-track/apps/fkanban")
  and (app("fkanban") | .install_mode == "artifact" and .artifact_app == "fkanban" and .install_root == "$HOME/.host-track/apps/fkanban")
  and (app("lastdb") | .install_mode == "artifact" and .artifact_app == "lastdb-bundle")
  and (app("lastdbd") | .install_mode == "artifact" and .artifact_app == "lastdb-bundle")
' "$default_registry" >/dev/null || fail "default registry did not cut over to expected artifact apps"

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

payload="$tmp/payload-demo"
printf '#!/usr/bin/env bash\necho demo\n' > "$payload"
sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
size="$(wc -c < "$payload" | tr -d ' ')"
digest="$(printf 'a%.0s' {1..64})"
oid="$(printf '1%.0s' {1..40})"
blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/demo" "$tmp/cas/manifests"
cp "$payload" "$blob"
jq -n \
  --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
  '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
    platform: "test-arm64", created_at: "2026-07-22T00:00:00Z",
    files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
    manifest_digest: $digest}' > "$tmp/cas/manifests/$digest.json"
cp "$tmp/cas/manifests/$digest.json" "$tmp/cas/channels/demo/stable.json"

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
      "notes": "proof fixture"
    }
  ]
}
EOF

"$ROOT/bin/host-track" install demo >/dev/null
proof="$tmp/proof.md"
"$ROOT/bin/last-stack-artifact-host-track-proof" --registry "$HOST_TRACK_REGISTRY" --proof "$proof" --json \
  | jq -e '.ok == true and .proof == "'"$proof"'"' >/dev/null || fail "proof helper did not return ok json"
grep -q '^PASS artifact-driven-host-track-registry-cutover ' "$proof" \
  || fail "proof helper did not write PASS proof"

fleet_home="$tmp/fleet-home"
mkdir -p "$fleet_home"
HOME="$fleet_home" "$ROOT/bin/last-stack-artifact-host-track-proof" --fleet --registry "$HOST_TRACK_REGISTRY" --json \
  | jq -e '.ok == true and (.proof | endswith("/.last-stack/feature-proofs/artifact-driven-host-track-fleet.md"))' \
    >/dev/null || fail "fleet proof helper did not return ok json with fleet proof path"
grep -q '^PASS artifact-driven-host-track-fleet ' \
  "$fleet_home/.last-stack/feature-proofs/artifact-driven-host-track-fleet.md" \
  || fail "fleet proof helper did not write PASS fleet proof"

jq '.apps += [{
  "app": "legacy",
  "install_mode": "checkout",
  "kind": "checkout-shim",
  "command": "legacy",
  "host_track": "'"$tmp"'/legacy"
}]' "$HOST_TRACK_REGISTRY" > "$tmp/bad-registry.json"

if "$ROOT/bin/last-stack-artifact-host-track-proof" --registry "$tmp/bad-registry.json" --proof "$tmp/bad-proof.md" >/dev/null 2>&1; then
  fail "proof helper passed checkout without exemption"
fi
if [ -f "$tmp/bad-proof.md" ]; then
  fail "proof helper wrote PASS proof for failing registry"
fi

printf 'ok: artifact host-track proof\n'
