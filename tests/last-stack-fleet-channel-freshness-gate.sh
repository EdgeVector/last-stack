#!/usr/bin/env bash
# Fixture tests for last-stack-fleet-channel-freshness-gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

GATE="$ROOT/bin/last-stack-fleet-channel-freshness-gate"
[ -x "$GATE" ] || fail "gate binary missing: $GATE"

# --- registry-only: default apps.json must pass pure policy ---
default_registry="$ROOT/config/host-track/apps.json"
out="$("$GATE" --registry-only --registry "$default_registry" --proof "$tmp/default-proof.md" --json)"
printf '%s\n' "$out" | jq -e '.ok == true and .mode == "registry-only"' >/dev/null \
  || fail "default registry failed registry-only gate: $out"
head -1 "$tmp/default-proof.md" | grep -q '^PASS ' || fail "default proof did not start with PASS"

# --- registry-only: intentional non-exempt non-artifact fails with named app ---
bad_registry="$tmp/bad-registry.json"
jq '.apps += [{
  "app": "rogue-fleet",
  "kind": "local-safe cli",
  "command": "rogue",
  "install_mode": "local-safe",
  "install_root": "$HOME/apps/rogue",
  "links": [{"source": "bin/rogue", "target": "$HOME/.local/bin/rogue"}],
  "notes": "intentional non-exempt non-artifact for gate test"
}]' "$default_registry" > "$bad_registry"

set +e
bad_out="$("$GATE" --registry-only --registry "$bad_registry" --proof "$tmp/bad-proof.md" --json 2>"$tmp/bad.err")"
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] || fail "non-exempt non-artifact should fail registry-only gate"
printf '%s\n' "$bad_out" | jq -e '
  .ok == false
  and any(.failures[]; .app == "rogue-fleet" and .code == "non-artifact-without-exemption")
' >/dev/null || fail "bad gate JSON missing named rogue-fleet failure: $bad_out"
head -1 "$tmp/bad-proof.md" | grep -q '^FAIL ' || fail "bad proof did not start with FAIL"
grep -q 'rogue-fleet' "$tmp/bad-proof.md" || fail "bad proof did not name rogue-fleet"

# --- full gate on a healthy fixture (fresh channel + restorable rollback) ---
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
  payload="$tmp/payload-$app-$digest"
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

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"

publish_fixture demo "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho demo'
publish_fixture demo "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho previous'

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
      "safe_upgrade": {
        "probes": [{"argv": ["bin/demo"], "timeout_s": 10}]
      },
      "notes": "fleet gate fixture"
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
        "rationale": "fixture remains checkout-backed"
      }
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

full_out="$("$GATE" --registry "$HOST_TRACK_REGISTRY" --proof "$tmp/full-proof.md" --json)"
printf '%s\n' "$full_out" | jq -e '
  .ok == true
  and .mode == "full"
  and (.policy | test("channel_fresh"))
' >/dev/null || fail "healthy fixture full gate failed: $full_out"
head -1 "$tmp/full-proof.md" | grep -q '^PASS ' || fail "full proof did not start with PASS"
grep -q 'previous version is restorable\|rollback' "$tmp/full-proof.md" \
  || grep -q 'demo' "$tmp/full-proof.md" \
  || fail "full proof missing demo/rollback evidence"

# Intentional break: force stale by removing current payload / tampering
printf 'tampered\n' > "$HOME/apps/demo/current/bin/demo"
set +e
stale_out="$("$GATE" --registry "$HOST_TRACK_REGISTRY" --proof "$tmp/stale-proof.md" --json 2>"$tmp/stale.err")"
stale_rc=$?
set -e
[ "$stale_rc" -ne 0 ] || fail "tampered demo should fail full gate"
printf '%s\n' "$stale_out" | jq -e '
  .ok == false
  and any(.failures[]; .app == "demo")
' >/dev/null || fail "stale/tamper failure must name demo: $stale_out"
head -1 "$tmp/stale-proof.md" | grep -q '^FAIL ' || fail "stale proof did not start with FAIL"
grep -q 'demo' "$tmp/stale-proof.md" || fail "stale proof did not name demo"

printf 'ok: last-stack-fleet-channel-freshness-gate\n'
