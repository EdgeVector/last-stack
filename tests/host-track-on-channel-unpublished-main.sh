#!/usr/bin/env bash
# On channel + unpublished main: check 0. Off channel: check 1. Bad content: check 1.
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

channel_oid="$(printf '1%.0s' {1..40})"
unpublished_oid="$(printf 'e%.0s' {1..40})"
export HOST_TRACK_TEST_MAIN_OID="$channel_oid"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = status ]; then
  oid="${HOST_TRACK_TEST_MAIN_OID:-}"
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || exit 3
  jq -n --arg oid "$oid" '{refs:[{name:"refs/heads/main",oid:$oid}]}'
  exit 0
fi
# `ref` is the point read host-track uses to resolve one tip. Same oid the
# `status` arm reports, in the real verb's tab-separated shape:
# "<oid>\t<ref name>\t<point|partition>".
if [ "${1:-}" = ref ]; then
  oid="${HOST_TRACK_TEST_MAIN_OID:-}"
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || exit 3
  printf '%s\t%s\t%s\n' "$oid" "refs/heads/${3:-main}" point
  exit 0
fi
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    --repo|--oid|--context|--manifest) shift 2 ;;
    --promote) shift ;;
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
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "install_mode": "artifact",
      "gate": "lastgit",
      "gate_main": "lastdb:///demo#main",
      "track_gate_main": true,
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/apps/demo",
      "links": [
        {"source": "bin/demo", "target": "$HOME/.local/bin/demo"}
      ],
      "notes": "on-channel unpublished-main fixture"
    }
  ]
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
    '{schema_version: 1, app: "demo", repo: "demo", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-08-20T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/demo/stable.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"

publish_fixture "$digest_one" "$channel_oid" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "install did not run"

# Unpublished main, live digest equals channel.
export HOST_TRACK_TEST_MAIN_OID="$unpublished_oid"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == false' >/dev/null \
  || fail "on-channel unpublished main reported stale=true: $st"
printf '%s\n' "$st" | jq -e '.main_unpublished == true' >/dev/null \
  || fail "on-channel unpublished main missing main_unpublished: $st"
printf '%s\n' "$st" | jq -e '.freshness == "soft_stale"' >/dev/null \
  || fail "on-channel unpublished main freshness: $st"
"$ROOT/bin/host-track" check demo >/dev/null \
  || fail "on-channel unpublished main failed check"

# Off channel: new published digest, live tree not updated.
publish_fixture "$digest_two" "$unpublished_oid" $'#!/usr/bin/env bash\necho v2'
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == true' >/dev/null \
  || fail "off-channel did not report stale=true: $st"
if "$ROOT/bin/host-track" check demo >/dev/null 2>&1; then
  fail "off-channel check exited 0"
fi

# Restore channel to digest_one and break content.
publish_fixture "$digest_one" "$channel_oid" $'#!/usr/bin/env bash\necho v1'
export HOST_TRACK_TEST_MAIN_OID="$unpublished_oid"
printf 'tampered\n' > "$HOME/apps/demo/current/bin/demo"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == false' >/dev/null \
  || fail "tampered on-channel should still be digest-current (stale=false): $st"
if "$ROOT/bin/host-track" check demo >/dev/null 2>&1; then
  fail "tampered content passed check"
fi

printf 'ok: on-channel unpublished main check 0; off-channel 1; bad content 1\n'
