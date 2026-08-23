#!/usr/bin/env bash
# Prove host-track refresh publishes last-stack-kanban-file-pr on the minimal
# routinesd PATH without relying on the source checkout or shell prelude.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
registry="$ROOT/config/host-track/apps.json"
helper_src="$ROOT/bin/last-stack-kanban-file-pr"
tmp="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

jq -e '
  .apps[]
  | select(.app == "last-stack")
  | any(.links[];
      .source == "bin/last-stack-kanban-file-pr"
      and .target == "$HOME/.local/bin/last-stack-kanban-file-pr")
' "$registry" >/dev/null \
  || fail "last-stack registry does not publish last-stack-kanban-file-pr"

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat >"$tmp/bin/lastgit" <<'SH'
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

sha="$(shasum -a 256 "$helper_src" | awk '{print $1}')"
size="$(wc -c < "$helper_src" | tr -d ' ')"
digest="$(printf 'a%.0s' {1..64})"
oid="$(printf '1%.0s' {1..40})"
blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/last-stack" "$tmp/cas/manifests"
cp "$helper_src" "$blob"

jq -n \
  --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
  '{schema_version: 1, app: "last-stack", repo: "EdgeVector/last-stack",
    source_oid: $oid, platform: "test-arm64", created_at: "2026-08-15T00:00:00Z",
    files: [{path: "bin/last-stack-kanban-file-pr", sha256: $sha, size: $size, mode: 493}],
    manifest_digest: $digest}' >"$tmp/cas/manifests/$digest.json"
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
          "source": "bin/last-stack-kanban-file-pr",
          "target": "$HOME/.local/bin/last-stack-kanban-file-pr"
        }
      ],
      "notes": "scheduled PATH-link fixture"
    }
  ]
}
EOF

"$ROOT/bin/host-track" refresh last-stack >/dev/null

expected="$HOME/.local/bin/last-stack-kanban-file-pr"
resolved="$(PATH="$HOME/.local/bin:/usr/bin:/bin" command -v last-stack-kanban-file-pr)"
[ "$resolved" = "$expected" ] || fail "PATH resolved $resolved, expected $expected"
[ -L "$expected" ] || fail "host-track refresh did not create PATH symlink"
[ "$(readlink "$expected")" = "$HOME/apps/last-stack/current/bin/last-stack-kanban-file-pr" ] \
  || fail "PATH symlink does not target artifacts/current: $(readlink "$expected")"

set +e
help_out="$(PATH="$HOME/.local/bin:/usr/bin:/bin" last-stack-kanban-file-pr --help 2>&1)"
help_rc=$?
set -e
[ "$help_rc" -eq 2 ] || fail "expected usage exit 2 from --help, got $help_rc"
printf '%s\n' "$help_out" | grep -q '^last-stack-kanban-file-pr ' \
  || fail "PATH-only --help did not execute the installed helper"

printf 'ok last-stack-kanban-file-pr-host-track-install\n'
