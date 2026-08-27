#!/usr/bin/env bash
# Prove Host Track publishes both ship-soak commands on a clean scheduled PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
registry="$ROOT/config/host-track/apps.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ship-soak-install.XXXXXX")"
cleanup() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for helper in last-stack-ship-soak-loom last-stack-ship-soak-tick; do
  jq -e --arg helper "$helper" '
    .apps[]
    | select(.app == "last-stack")
    | any(.links[];
        .source == ("bin/" + $helper)
        and .target == ("$HOME/.local/bin/" + $helper))
  ' "$registry" >/dev/null \
    || fail "last-stack registry does not publish $helper"
done

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas/channels/last-stack" \
  "$tmp/cas/manifests" "$tmp/cas/blobs/sha256"

cat >"$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --app|--channel) shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
cat "$root/channels/last-stack/stable.json"
SH
chmod +x "$tmp/bin/lastgit"

files='[]'
for helper in last-stack-ship-soak-loom last-stack-ship-soak-tick; do
  source_path="$ROOT/bin/$helper"
  sha="$(shasum -a 256 "$source_path" | awk '{print $1}')"
  size="$(wc -c < "$source_path" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")"
  cp "$source_path" "$blob"
  files="$(jq -cn --argjson files "$files" --arg helper "$helper" \
    --arg sha "$sha" --argjson size "$size" \
    '$files + [{path:("bin/" + $helper), sha256:$sha, size:$size, mode:493}]')"
done

digest="$(printf 'a%.0s' {1..64})"
oid="$(printf '1%.0s' {1..40})"
jq -n --arg digest "$digest" --arg oid "$oid" --argjson files "$files" \
  '{schema_version:1, app:"last-stack", repo:"EdgeVector/last-stack",
    source_oid:$oid, platform:"test-arm64", created_at:"2026-08-27T00:00:00Z",
    files:$files, manifest_digest:$digest}' >"$tmp/cas/manifests/$digest.json"
cp "$tmp/cas/manifests/$digest.json" "$tmp/cas/channels/last-stack/stable.json"

cat >"$HOST_TRACK_REGISTRY" <<EOF
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "artifact_root": "$tmp/cas"
  },
  "apps": [
    {
      "app": "last-stack",
      "kind": "artifact skill-pack",
      "command": "host-track",
      "install_root": "$HOME/apps/last-stack",
      "links": [
        {
          "source": "bin/last-stack-ship-soak-loom",
          "target": "$HOME/.local/bin/last-stack-ship-soak-loom"
        },
        {
          "source": "bin/last-stack-ship-soak-tick",
          "target": "$HOME/.local/bin/last-stack-ship-soak-tick"
        }
      ],
      "notes": "ship-soak clean PATH fixture"
    }
  ]
}
EOF

"$ROOT/bin/host-track" refresh last-stack >/dev/null

for helper in last-stack-ship-soak-loom last-stack-ship-soak-tick; do
  expected="$HOME/.local/bin/$helper"
  resolved="$(PATH="$HOME/.local/bin:/usr/bin:/bin" command -v "$helper")"
  [ "$resolved" = "$expected" ] || fail "PATH resolved $resolved, expected $expected"
  [ -L "$expected" ] || fail "Host Track did not link $helper"
  [ "$(readlink "$expected")" = "$HOME/apps/last-stack/current/bin/$helper" ] \
    || fail "$helper does not target artifacts/current"
  PATH="$HOME/.local/bin:/usr/bin:/bin" "$helper" --help >/dev/null \
    || fail "$helper --help failed on the clean PATH"
done

printf 'ok last-stack-ship-soak-host-track-install\n'
