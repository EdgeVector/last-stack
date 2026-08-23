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
export HOST_TRACK_SOAK_FILE_CARD=0
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

concurrent_pids=()
for i in 1 2 3 4 5; do
  HOST_TRACK_INSTALL_LOCK_TIMEOUT_SEC=10 "$ROOT/bin/host-track" refresh --force demo \
    > "$tmp/concurrent-refresh-$i.out" 2> "$tmp/concurrent-refresh-$i.err" &
  concurrent_pids+=("$!")
done
for pid in "${concurrent_pids[@]}"; do
  if ! wait "$pid"; then
    cat "$tmp"/concurrent-refresh-*.err >&2
    fail "concurrent forced artifact refresh failed"
  fi
done
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_two" ] \
  || fail "concurrent refresh changed current away from the complete version"
[ "$(demo)" = v2 ] || fail "concurrent refresh left current/bin unresolved"
"$ROOT/bin/host-track" check demo >/dev/null \
  || fail "concurrent refresh left active artifact unverifiable"
nested_stage_count="$(find "$HOME/apps/demo/versions/$digest_two" -type d -name '.stage-*' | wc -l | tr -d ' ')"
[ "$nested_stage_count" = "0" ] \
  || fail "concurrent refresh published a stage directory inside the immutable version"

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

# ── install lock: live holder blocks; dead pid is reclaimed ────────────────
# Restore a good channel tip first — the previous case left stable pointing at
# a deliberately corrupt digest so install fails closed.
publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
lock_dir="${HOST_TRACK_LOCK_DIR:-$HOME/.host-track/locks}"
mkdir -p "$lock_dir"
fake_lock="$lock_dir/install-demo.lock.d"
rm -rf -- "$fake_lock"
mkdir "$fake_lock"
# Hold with THIS shell's pid so kill -0 succeeds → no reclaim by pid_dead.
printf '%s\n' "$$" >"$fake_lock/pid"
export HOST_TRACK_INSTALL_LOCK_WAIT_S=2
export HOST_TRACK_INSTALL_LOCK_STALE_S=999999
set +e
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/lock-block.err"
block_rc=$?
set -e
[ "$block_rc" -ne 0 ] || fail "refresh should fail while install lock is held by live pid"
grep -q 'install lock timeout' "$tmp/lock-block.err" \
  || fail "expected lock timeout message (got: $(cat "$tmp/lock-block.err"))"
# Dead pid reclaim
printf '999999\n' >"$fake_lock/pid"
export HOST_TRACK_INSTALL_LOCK_WAIT_S=10
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/lock-reclaim.err" \
  || fail "refresh did not reclaim dead-pid lock: $(cat "$tmp/lock-reclaim.err")"
[ ! -d "$fake_lock" ] || fail "dead-pid lock dir was not reclaimed"
[ "$(demo)" = v1 ] || fail "after lock-reclaim refresh demo broke"
unset HOST_TRACK_INSTALL_LOCK_WAIT_S HOST_TRACK_INSTALL_LOCK_STALE_S

# ── stage GC: abandoned .stage-* older than max age are removed ────────────
stale_stage="$HOME/apps/demo/.stage-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef.XXXX"
mkdir -p "$stale_stage/bin"
printf 'orphan\n' >"$stale_stage/bin/x"
# Age the stage past the GC threshold (touch -t needs local time; use epoch via perl/python).
python3 - "$stale_stage" <<'PY'
import os, sys, time
path = sys.argv[1]
old = time.time() - 7200  # 2h ago
os.utime(path, (old, old))
PY
export HOST_TRACK_STAGE_GC_MAX_AGE_S=60
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/stage-gc.err" \
  || fail "refresh with stage-gc failed: $(cat "$tmp/stage-gc.err")"
[ ! -d "$stale_stage" ] || fail "stale .stage-* dir was not garbage-collected"
grep -q 'gc stale stage dir' "$tmp/stage-gc.err" \
  || fail "expected stage GC log line (got: $(cat "$tmp/stage-gc.err"))"
[ "$(demo)" = v1 ] || fail "stage GC refresh broke active demo"
unset HOST_TRACK_STAGE_GC_MAX_AGE_S

printf 'ok: verified artifact install/refresh/rollback/tamper rejection\n'

# ── track_gate_main: on-channel vs unpublished main; refresh promotes ─────
# stale = live digest equals published channel. main_unpublished = lastgit
# main is ahead of that channel. Refresh promotes a green+published tip.
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

# Install while main tip == v1 → on channel, not unpublished.
printf '%s' "$oid_v1" > "$MAIN_TIP_FILE"
"$ROOT/bin/host-track" install skillpack >/dev/null
[ "$(demo)" = v1 ] || fail "track-main install did not land v1"
st="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st" | jq -e --arg tip "$oid_v1" '
  .gate_head == $tip and .stale == false and .host_head == $tip
  and .main_unpublished == false and .freshness == "fresh"
' >/dev/null || fail "in-sync main tip should not be stale: $st"
"$ROOT/bin/host-track" check skillpack >/dev/null \
  || fail "in-sync main tip failed check"

# Advance main tip to v2 (green+published). Status stays on-channel.
# Lag is main_unpublished. Pickup check must stay 0. Refresh installs v2.
printf '%s' "$oid_v2" > "$MAIN_TIP_FILE"
st_lag="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st_lag" | jq -e --arg old "$oid_v1" --arg ch "$digest_v1" '
  .gate_head == $old
  and .host_head == $old
  and .stale == false
  and .main_unpublished == true
  and .freshness == "soft_stale"
  and .manifest_digest == $ch
' >/dev/null || fail "on-channel unpublished-main lag not reported: $st_lag"
"$ROOT/bin/host-track" check skillpack >/dev/null \
  || fail "on-channel unpublished-main failed check"

"$ROOT/bin/host-track" refresh skillpack >/dev/null
[ "$(demo)" = v2 ] || fail "refresh did not install advanced main tip"
st2="$("$ROOT/bin/host-track" status --json skillpack)"
printf '%s\n' "$st2" | jq -e --arg tip "$oid_v2" '
  .stale == false and .host_head == $tip and .gate_head == $tip
  and .main_unpublished == false and .freshness == "fresh"
' >/dev/null || fail "after refresh still not tracking main: $st2"
jq -e --arg tip "$oid_v2" '.source_oid == $tip' \
  "$tmp/cas/channels/skillpack/stable.json" >/dev/null \
  || fail "stable channel was not promoted to new main tip"

printf 'ok: track_gate_main promotes green main and reports unpublished-main lag\n'

# ── dist/* producers (situations/fkanban layout) — no synthetic bin/ ─────────
# Fleet proof failed with "staged artifact missing bin/ (incomplete stage)" when
# CAS only published dist/situations + dist/fsituations. Registry links point at
# dist/*; host-track must accept that as a complete payload.
dist_app_home="$tmp/dist-app-home"
mkdir -p "$dist_app_home/.local/bin" "$tmp/cas/channels/sitcli" "$tmp/cas/manifests"
export HOME="$dist_app_home"
export PATH="$dist_app_home/.local/bin:$tmp/bin:$PATH"
export HOST_TRACK_REGISTRY="$tmp/dist-registry.json"
export HOST_TRACK_STAMP_DIR="$dist_app_home/stamps"
mkdir -p "$HOST_TRACK_STAMP_DIR"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable"
  },
  "apps": [
    {
      "app": "sitcli",
      "kind": "artifact-bundle",
      "command": "sitcli",
      "artifact_app": "sitcli",
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/apps/sitcli",
      "links": [
        {"source": "dist/sitcli", "target": "$HOME/.local/bin/sitcli"}
      ],
      "notes": "dist-only payload regression (situations/fkanban shape)"
    }
  ]
}
JSON

publish_dist_fixture() {
  local digest="$1" oid="$2" content="$3" payload sha size blob manifest
  payload="$tmp/dist-payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: "sitcli", repo: "EdgeVector/sitcli", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-08-06T00:00:00Z",
      files: [{path: "dist/sitcli", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/sitcli/stable.json"
}

# lastgit stub already on PATH from earlier fixture; ensure resolve still works
# for sitcli via the same stub shape — re-install a lastgit that serves sitcli.
cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "artifact" ] && [ "${2:-}" = "resolve" ]; then
  app=""
  channel="stable"
  root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --channel) channel="$2"; shift 2 ;;
      --root) root="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cat "$root/channels/$app/$channel.json"
  exit 0
fi
if [ "${1:-}" = "ci" ] && [ "${2:-}" = "status" ]; then
  echo '{"state":"success","contexts":[{"context":"ci-required","state":"success"}]}'
  exit 0
fi
echo "unexpected lastgit $*" >&2
exit 1
SH
chmod +x "$tmp/bin/lastgit"

digest_dist="$(printf 'd%.0s' {1..64})"
oid_dist="$(printf '4%.0s' {1..40})"
publish_dist_fixture "$digest_dist" "$oid_dist" $'#!/usr/bin/env bash\necho dist-ok'

# Must NOT die with "missing bin/ (incomplete stage)"
if ! "$ROOT/bin/host-track" install sitcli >/dev/null 2>"$tmp/dist-install.err"; then
  fail "dist-only install failed (expected complete stage via links): $(cat "$tmp/dist-install.err")"
fi
[ "$(readlink "$HOME/apps/sitcli/current")" = "versions/$digest_dist" ] \
  || fail "dist-only install did not activate versions/$digest_dist"
[ -x "$HOME/apps/sitcli/current/dist/sitcli" ] \
  || fail "dist-only payload missing current/dist/sitcli"
[ ! -d "$HOME/apps/sitcli/current/bin" ] \
  || fail "dist-only fixture unexpectedly grew a bin/ tree"
[ "$(sitcli)" = dist-ok ] || fail "dist-only PATH link did not run sitcli"
"$ROOT/bin/host-track" status --json sitcli | jq -e \
  --arg d "$digest_dist" \
  '.install_mode == "artifact" and .stale == false and .manifest_digest == $d' >/dev/null \
  || fail "dist-only status not fresh after install"
"$ROOT/bin/host-track" refresh --force-if-stale sitcli >/dev/null 2>"$tmp/dist-refresh.err" \
  || fail "dist-only refresh failed: $(cat "$tmp/dist-refresh.err")"
[ "$(sitcli)" = dist-ok ] || fail "dist-only still works after refresh"

# Retired PATH names: unlink leftover shims that still point at this
# install_root; leave foreign symlinks and regular files alone.
ln -s "$HOME/apps/sitcli/current/dist/sitcli" "$HOME/.local/bin/sitcli-legacy"
ln -s /usr/bin/true "$HOME/.local/bin/sitcli-foreign"
printf 'keep-me\n' > "$HOME/.local/bin/sitcli-plain"
jq '.apps[0].retired_links = [
  {"target": "$HOME/.local/bin/sitcli-legacy"},
  {"target": "$HOME/.local/bin/sitcli-foreign"},
  {"target": "$HOME/.local/bin/sitcli-plain"}
]' "$HOST_TRACK_REGISTRY" > "$tmp/dist-registry-retired.json"
mv "$tmp/dist-registry-retired.json" "$HOST_TRACK_REGISTRY"
"$ROOT/bin/host-track" install sitcli >/dev/null 2>"$tmp/dist-retire.err" \
  || fail "install with retired_links failed: $(cat "$tmp/dist-retire.err")"
[ ! -e "$HOME/.local/bin/sitcli-legacy" ] \
  || fail "retired link pointing at this install_root was not removed"
[ -L "$HOME/.local/bin/sitcli-foreign" ] \
  || fail "retired_links deleted a symlink this install does not own"
[ -f "$HOME/.local/bin/sitcli-plain" ] && [ ! -L "$HOME/.local/bin/sitcli-plain" ] \
  || fail "retired_links deleted or replaced a regular file"
[ "$(sitcli)" = dist-ok ] || fail "live sitcli link broke after retiring leftovers"

printf 'ok: dist-only artifact install/refresh (no synthetic bin/) \n'
