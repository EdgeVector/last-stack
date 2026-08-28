#!/usr/bin/env bash
# Probe-before-cutover: a RED candidate must not flip current/PATH.
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
export HOST_TRACK_PROBE_RETRY_DELAY_S=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat > "$HOME/post-install" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "$HOST_TRACK_APP" "$HOST_TRACK_MANIFEST_DIGEST" > "$HOME/post-install-ran"
SH
chmod +x "$HOME/post-install"

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
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/apps/demo",
      "post_install": "$HOME/post-install",
      "links": [
        {"source": "bin/demo", "target": "$HOME/.local/bin/demo"}
      ],
      "safe_upgrade": {
        "probes": [
          {"argv": ["bin/demo"], "timeout_s": 10, "output_matches": "ok"}
        ]
      },
      "notes": "probe-before-cutover fixture"
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
    '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-07-21T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/demo/stable.json"
}

digest_good="$(printf 'a%.0s' {1..64})"
digest_bad="$(printf 'b%.0s' {1..64})"
digest_transient="$(printf 'c%.0s' {1..64})"
oid_good="$(printf '1%.0s' {1..40})"
oid_bad="$(printf '2%.0s' {1..40})"
oid_transient="$(printf '3%.0s' {1..40})"

publish_fixture "$digest_good" "$oid_good" $'#!/usr/bin/env bash\necho ok-v1'
"$ROOT/bin/host-track" install demo >/dev/null \
  || fail "green first install should activate"
[ "$(demo)" = ok-v1 ] || fail "first install did not run: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_good" ] \
  || fail "first install current pointer wrong"

publish_fixture "$digest_transient" "$oid_transient" $'#!/usr/bin/env bash\nmarker="$HOME/transient-probe-count"\ncount="$(cat "$marker" 2>/dev/null || printf 0)"\ncount=$((count + 1))\nprintf "%s\\n" "$count" >"$marker"\nif [ "$count" -eq 1 ]; then echo transient >&2; exit 1; fi\necho ok-v2'
"$ROOT/bin/host-track" refresh demo >/dev/null 2>"$tmp/transient.err" \
  || fail "a transient probe failure should recover"
grep -q 'probe attempt 1/3 failed' "$tmp/transient.err" \
  || fail "transient failure did not name attempt 1/3: $(cat "$tmp/transient.err")"
grep -q 'probe recovered attempt=2/3' "$tmp/transient.err" \
  || fail "transient probe did not report recovery: $(cat "$tmp/transient.err")"
! grep -q 'probe RED' "$tmp/transient.err" \
  || fail "transient recovery still reported RED: $(cat "$tmp/transient.err")"
[ "$(demo)" = ok-v2 ] || fail "recovered candidate did not activate: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_transient" ] \
  || fail "recovered candidate current pointer wrong"

publish_fixture "$digest_bad" "$oid_bad" $'#!/usr/bin/env bash\necho broken\nexit 1'
if "$ROOT/bin/host-track" refresh demo >/dev/null 2>"$tmp/red.err"; then
  fail "RED probe refresh should fail closed"
fi
grep -q 'probe attempt 1/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 1"
grep -q 'probe attempt 2/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 2"
grep -q 'probe attempt 3/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 3"
grep -q 'probe RED after 3 attempts' "$tmp/red.err" \
  || fail "refresh did not report final probe RED: $(cat "$tmp/red.err")"
[ "$(demo)" = ok-v2 ] || fail "RED probe changed the live command: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_transient" ] \
  || fail "RED probe flipped current"
[ ! -e "$HOME/.local/bin/demo" ] || [ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/current/bin/demo" ] \
  || true
# PATH still points at current (good tree).
[ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/current/bin/demo" ] \
  || [ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/versions/$digest_transient/bin/demo" ] \
  || fail "PATH link left the good tree"

# Bad version may exist on disk (staged) but must not be current.
if [ -L "$HOME/apps/demo/current" ]; then
  [ "$(readlink "$HOME/apps/demo/current")" != "versions/$digest_bad" ] \
    || fail "current points at RED candidate"
fi

# Skip-probe is the Tom-only override and must actually activate.
HOST_TRACK_PROBE_SKIP=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null \
  || fail "HOST_TRACK_PROBE_SKIP should allow activation"
skip_out="$(demo || true)"
[ "$skip_out" = broken ] || fail "skip-probe did not activate the new binary: $skip_out"

printf 'ok: host-track probe-before-cutover\n'
