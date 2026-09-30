#!/usr/bin/env bash
# host-track with a GitHub gate_main (https://github.com/OWNER/NAME.git#main):
#   - status reads the branch tip with `gh api` and reports main_unpublished
#   - refresh runs last-stack-github-artifact-pull (HOST_TRACK_GITHUB_PULL here)
#     with the app's artifact name, repo, branch, channel, CAS root and platform
#   - a pull hold (rc 3) or failure keeps the channel and does not fail refresh
#   - the pull promotes stable, then the normal install flow picks it up
# Fixture-only: fake gh, fake puller, temp HOME, temp install root.
# Brain: design-github-artifact-publish-path
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_SOAK_FILE_CARD=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"

# lastgit: only `artifact resolve` (host-track's reader of the CAS channel).
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

# Fake puller: log the argv; rc from $tmp/pull-rc; on rc 0 flip stable to v2.
cat > "$tmp/bin/fake-pull" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/pull.log"
rc="\$(cat "$tmp/pull-rc" 2>/dev/null || echo 0)"
if [ "\$rc" = 0 ]; then cp "$tmp/cas/manifests/$digest_two.json" "$tmp/cas/channels/demo/stable.json"; fi
exit "\$rc"
SH
chmod +x "$tmp/bin/fake-pull"
export HOST_TRACK_GITHUB_PULL="$tmp/bin/fake-pull"

export HOST_TRACK_GH="$ROOT/tests/fixtures/github-artifact/fake-gh"
chmod +x "$HOST_TRACK_GH"
export FAKE_GH_ROUTES="$tmp/routes.json"
set_tip() {
  jq -n --arg oid "$1" '{"repos/EdgeVector/demo/git/ref/heads/main": {json: {object: {sha: $oid}}}}' > "$FAKE_GH_ROUTES"
}
set_tip "$oid_one"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {"install_mode": "artifact", "artifact_channel": "stable"},
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "install_mode": "artifact",
      "command": "demo",
      "gate": "github",
      "gate_main": "https://github.com/EdgeVector/demo.git#main",
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "github gate fixture"
    }
  ]
}
JSON

stage_manifest() {
  local digest="$1" oid="$2" content="$3" payload sha size
  payload="$tmp/payload-$digest"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  mkdir -p "$tmp/cas/blobs/sha256/${sha:0:2}" "$tmp/cas/channels/demo" "$tmp/cas/manifests"
  cp "$payload" "$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  jq -n --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: "demo", repo: "demo", source_oid: $oid, platform: "test-arm64",
      created_at: "2026-09-30T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}], manifest_digest: $digest}' \
    > "$tmp/cas/manifests/$digest.json"
}
stage_manifest "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
stage_manifest "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho v2'
cp "$tmp/cas/manifests/$digest_one.json" "$tmp/cas/channels/demo/stable.json"

printf "3\n" > "$tmp/pull-rc"  # baseline install must not pull
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "baseline install did not run"

# 1. status: branch tip == channel oid -> published; tip ahead -> main_unpublished.
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.main_unpublished == false' >/dev/null || fail "tip == channel reported unpublished: $st"
set_tip "$oid_two"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.main_unpublished == true and .gate == "github"' >/dev/null \
  || fail "tip ahead of channel not reported as main_unpublished: $st"

# 2. hold (rc 3): channel kept, refresh does not fail, install unchanged.
printf '3\n' > "$tmp/pull-rc"
"$ROOT/bin/host-track" refresh demo >"$tmp/out" 2>"$tmp/err" || fail "refresh failed on a pull hold: $(cat "$tmp/err")"
grep -q 'not yet green+published; keeping channel=stable' "$tmp/err" || fail "hold not reported: $(cat "$tmp/err")"
[ "$(demo)" = v1 ] || fail "hold changed the install"

# 3. failure (rc 1): same, with the failure line.
printf '1\n' > "$tmp/pull-rc"
"$ROOT/bin/host-track" refresh demo >"$tmp/out" 2>"$tmp/err" || fail "refresh failed on a pull failure"
grep -q 'github artifact pull failed (rc=1); keeping channel=stable' "$tmp/err" || fail "failure not reported: $(cat "$tmp/err")"
[ "$(demo)" = v1 ] || fail "pull failure changed the install"

# 4. success: the pull promotes stable, refresh installs it.
printf '0\n' > "$tmp/pull-rc"
"$ROOT/bin/host-track" refresh demo >"$tmp/out" 2>"$tmp/err" || fail "refresh failed: $(cat "$tmp/err")"
[ "$(demo)" = v2 ] || fail "refresh did not install the pulled artifact"
last="$(tail -n 1 "$tmp/pull.log")"
case "$last" in
  "--app demo --repo EdgeVector/demo --branch main --channel stable --root $tmp/home/../cas --platform "*) ;;
  *) fail "puller argv wrong: $last" ;;
esac

echo "ok host-track-github-gate"
