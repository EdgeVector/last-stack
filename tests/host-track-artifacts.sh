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
while IFS=$'\t' read -r digest size; do
  blob="$root/blobs/sha256/${digest:0:2}/$digest"
  [ -f "$blob" ] || exit 4
  [ "$(wc -c < "$blob" | tr -d ' ')" = "$size" ] || exit 5
  [ "$(shasum -a 256 "$blob" | awk '{print $1}')" = "$digest" ] || exit 6
done < <(jq -r '.files[] | [.sha256, (.size | tostring)] | @tsv' "$manifest")
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
      "notes": "artifact install test"
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

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
digest_bad="$(printf 'c%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
oid_bad="$(printf '3%.0s' {1..40})"

publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(cut -f1 "$HOME/post-install-ran")" = demo ] || fail "artifact post-install did not run"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_one" ] || fail "first install was not activated"
[ "$(demo)" = v1 ] || fail "first installed command did not run"
jq -e --arg digest "$digest_one" '.manifest_digest == $digest and .install_mode == "artifact"' \
  "$HOST_TRACK_STAMP_DIR/demo.json" >/dev/null || fail "artifact stamp is incomplete"
"$ROOT/bin/host-track" status --json demo | jq -e '.install_mode == "artifact" and .stale == false' >/dev/null \
  || fail "installed artifact did not report fresh"
"$ROOT/bin/host-track" check demo >/dev/null || fail "verified active artifact failed check"
"$ROOT/bin/host-track" refresh demo >/dev/null
jq -e --arg oid "$oid_one" '.source_oid == $oid' "$HOST_TRACK_STAMP_DIR/demo.json" >/dev/null \
  || fail "no-op artifact refresh dropped source provenance"
cp "$HOME/apps/demo/current/bin/demo" "$tmp/active-backup"
printf 'tampered install\n' > "$HOME/apps/demo/current/bin/demo"
if "$ROOT/bin/host-track" check demo >/dev/null 2>&1; then
  fail "tampered active install passed check"
fi
# Tampered install must name the bad path.
tamper_err="$("$ROOT/bin/host-track" check demo 2>&1 >/dev/null || true)"
printf '%s\n' "$tamper_err" | grep -q 'hash mismatch: path=bin/demo' \
  || fail "check did not name hash-mismatched path (got: $tamper_err)"

# Plain refresh (status.stale=false) must re-stage corrupt content, not no-op.
"$ROOT/bin/host-track" refresh demo >/dev/null
"$ROOT/bin/host-track" check demo >/dev/null \
  || fail "refresh did not heal tampered active install"
[ "$(demo)" = v1 ] || fail "healed install lost working binary"

# Re-tamper then force-refresh path
printf 'tampered again\n' > "$HOME/apps/demo/current/bin/demo"
"$ROOT/bin/host-track" refresh --force demo >/dev/null
"$ROOT/bin/host-track" check demo >/dev/null \
  || fail "force refresh did not heal tampered active install"

cp "$tmp/active-backup" "$HOME/apps/demo/current/bin/demo" 2>/dev/null || true
chmod +x "$HOME/apps/demo/current/bin/demo" 2>/dev/null || true

publish_fixture "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho v2'
"$ROOT/bin/host-track" status --json demo | jq -e '.stale == true' >/dev/null \
  || fail "new promoted artifact did not report stale"
"$ROOT/bin/host-track" refresh demo >/dev/null
[ "$(demo)" = v2 ] || fail "refresh did not atomically activate v2"
[ "$(readlink "$HOME/apps/demo/previous")" = "versions/$digest_one" ] || fail "previous version was not retained"

"$ROOT/bin/host-track" rollback demo >/dev/null
[ "$(demo)" = v1 ] || fail "rollback did not reactivate v1"
[ "$(readlink "$HOME/apps/demo/previous")" = "versions/$digest_two" ] || fail "rollback did not retain displaced version"

chmod -R u+w "$HOME/apps/demo/versions/$digest_one" 2>/dev/null || true
rm -rf "$HOME/apps/demo/versions/$digest_one"
dangling_status="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$dangling_status" | jq -e --arg target "versions/$digest_one" '
  .stale == true
  and .artifact_current == $target
  and (.artifact_problem | contains("dangling current target"))
  and (.artifact_problem | contains($target))
' >/dev/null || fail "dangling current was not diagnosed in status: $dangling_status"
check_err="$("$ROOT/bin/host-track" check demo 2>&1 >/dev/null || true)"
printf '%s\n' "$check_err" | grep -q "artifact install broken: dangling current target: target=versions/$digest_one" \
  || fail "check did not distinguish dangling current from PATH failure (got: $check_err)"
which_err="$("$ROOT/bin/host-track" which demo 2>&1 >/dev/null || true)"
printf '%s\n' "$which_err" | grep -q "artifact install broken: dangling current target: target=versions/$digest_one" \
  || fail "which did not distinguish dangling current from PATH failure (got: $which_err)"
publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" refresh --force demo >/dev/null
"$ROOT/bin/host-track" check demo >/dev/null \
  || fail "force refresh did not repair dangling current"
[ "$(demo)" = v1 ] || fail "dangling current repair did not restore v1"

publish_fixture "$digest_bad" "$oid_bad" $'#!/usr/bin/env bash\necho tampered'
bad_sha="$(jq -r '.files[0].sha256' "$tmp/cas/channels/demo/stable.json")"
printf 'corrupt\n' > "$tmp/cas/blobs/sha256/${bad_sha:0:2}/$bad_sha"
if "$ROOT/bin/host-track" install demo >/dev/null 2>&1; then
  fail "tampered artifact installed"
fi
[ "$(demo)" = v1 ] || fail "failed install changed the active version"
[ ! -e "$HOME/apps/demo/versions/$digest_bad" ] || fail "failed install left an immutable version"

printf 'ok: verified artifact install/refresh/rollback/tamper rejection\n'

# ── track_gate_main: status stale vs main tip; refresh promotes channel ─────
# Mental model: live skill-pack tracks green main, not a frozen stable pointer.
# Use app name != last-stack so install does not chmod a-w the version tree.
MAIN_TIP_FILE="$tmp/main-tip-oid"
printf '%s' "$(printf 'a%.0s' {1..40})" > "$MAIN_TIP_FILE"

cat > "$tmp/bin/lastgit" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = status ]; then
  tip="\$(cat "$MAIN_TIP_FILE")"
  jq -n --arg tip "\$tip" \
    '{repo:"skillpack",refs:[{name:"refs/heads/main",oid:\$tip}]}'
  exit 0
fi
if [ "\${1:-}" = ci ] && [ "\${2:-}" = status ]; then
  jq -n --arg oid "\${3:-}" '{oid:\$oid,context:"ci-required",state:"success"}'
  exit 0
fi
if [ "\${1:-}" = artifact ] && [ "\${2:-}" = promote ]; then
  shift 2
  app="" channel="" manifest="" repo="" oid="" root=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --app) app="\$2"; shift 2 ;;
      --channel) channel="\$2"; shift 2 ;;
      --manifest) manifest="\$2"; shift 2 ;;
      --repo) repo="\$2"; shift 2 ;;
      --oid) oid="\$2"; shift 2 ;;
      --root) root="\$2"; shift 2 ;;
      --context|--json) shift ;;
      --context=*) shift ;;
      *) shift ;;
    esac
  done
  src="\$root/manifests/\$manifest.json"
  [ -f "\$src" ] || exit 9
  mkdir -p "\$root/channels/\$app"
  cp "\$src" "\$root/channels/\$app/\$channel.json"
  jq -n --arg d "\$manifest" --arg o "\$oid" '{manifest_digest:\$d,source_oid:\$o,promoted:true}'
  exit 0
fi
if [ "\${1:-}" = artifact ] && [ "\${2:-}" = resolve ]; then
  shift 2
  app="" channel="" root=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --app) app="\$2"; shift 2 ;;
      --channel) channel="\$2"; shift 2 ;;
      --root) root="\$2"; shift 2 ;;
      --json) shift ;;
      *) exit 2 ;;
    esac
  done
  cat "\$root/channels/\$app/\$channel.json"
  exit 0
fi
exit 2
SH
chmod +x "$tmp/bin/lastgit"

chmod -R u+w "$HOME/apps" 2>/dev/null || true
rm -rf "$tmp/cas" "$tmp/stamps" "$HOME/apps" "$HOME/post-install-ran" 2>/dev/null || true
mkdir -p "$tmp/cas" "$tmp/stamps" "$HOME/apps"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"

digest_v1="$(printf 'd%.0s' {1..64})"
digest_v2="$(printf 'e%.0s' {1..64})"
oid_v1="$(printf 'a%.0s' {1..40})"
oid_v2="$(printf 'c%.0s' {1..40})"

publish_sp() {
  local digest="$1" oid="$2" content="$3" payload sha size blob manifest
  payload="$tmp/payload-sp"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/skillpack" "$tmp/cas/manifests" \
    "$tmp/cas/builds/skillpack/$oid"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: "skillpack", repo: "skillpack", source_oid: $oid,
      platform: "darwin-arm64", created_at: "2026-07-31T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/builds/skillpack/$oid/darwin-arm64.json"
  cp "$manifest" "$tmp/cas/builds/skillpack/$oid/linux-x64.json"
}

publish_sp "$digest_v1" "$oid_v1" $'#!/usr/bin/env bash\necho v1'
cp "$tmp/cas/manifests/$digest_v1.json" "$tmp/cas/channels/skillpack/stable.json"
publish_sp "$digest_v2" "$oid_v2" $'#!/usr/bin/env bash\necho v2'

cat > "$HOST_TRACK_REGISTRY" <<JSON
{
  "defaults": { "install_mode": "artifact", "artifact_channel": "stable" },
  "apps": [{
    "app": "skillpack",
    "kind": "artifact skill-pack",
    "command": "demo",
    "gate_main": "lastdb:///skillpack#main",
    "track_gate_main": true,
    "artifact_app": "skillpack",
    "artifact_channel": "stable",
    "artifact_root": "\$HOME/../cas",
    "install_root": "\$HOME/apps/skillpack",
    "post_install": "\$HOME/post-install",
    "links": [{"source": "bin/demo", "target": "\$HOME/.local/bin/demo"}]
  }]
}
JSON

# Install while main tip == v1 → fresh.
printf '%s' "$oid_v1" > "$MAIN_TIP_FILE"
"$ROOT/bin/host-track" install skillpack >/dev/null
[ "$(demo)" = v1 ] || fail "track-main install did not land v1"
st="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st" | jq -e --arg tip "$oid_v1" '
  .gate_head == $tip and .stale == false and .host_head == $tip
' >/dev/null || fail "in-sync main tip should not be stale: $st"

# Advance main tip to v2 (green+published); installed lags → stale.
printf '%s' "$oid_v2" > "$MAIN_TIP_FILE"
st_lag="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st_lag" | jq -e --arg tip "$oid_v2" --arg old "$oid_v1" '
  .gate_head == $tip and .stale == true and .host_head == $old
' >/dev/null || fail "lag vs advanced main tip not reported: $st_lag"

"$ROOT/bin/host-track" refresh skillpack >/dev/null
[ "$(demo)" = v2 ] || fail "refresh did not install advanced main tip"
st2="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st2" | jq -e --arg tip "$oid_v2" '
  .stale == false and .host_head == $tip and .gate_head == $tip
' >/dev/null || fail "after refresh still not tracking main: $st2"
jq -e --arg tip "$oid_v2" '.source_oid == $tip' \
  "$tmp/cas/channels/skillpack/stable.json" >/dev/null \
  || fail "stable channel was not promoted to new main tip"

printf 'ok: track_gate_main promotes green main and reports lag correctly\n'
