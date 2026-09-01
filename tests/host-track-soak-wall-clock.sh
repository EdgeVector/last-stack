#!/usr/bin/env bash
# `host-track status` must report the wall clock that DECIDES the soak flip.
#
# `soak_watch_one` gates on both halves:
#
#   if [ "$elapsed" -lt "$need" ] || [ "$checks" -lt "$min_checks" ]
#
# and its own comment says the check count is the backstop, not the gate. Recent
# last-stack soaks activate at 10-15 checks against min_checks=3, so a status
# line carrying only `checks/min_checks` reads as over-satisfied for most of the
# window's life -- a soaking canary rendered as a stuck promotion.
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

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) shift 2 ;;
    --channel) shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
cat "$root/channels/demo/stable.json"
SH
chmod +x "$tmp/bin/lastgit"

write_registry() {
  local soak_hours="$1"
  cat > "$HOST_TRACK_REGISTRY" <<JSON
{
  "defaults": {"install_mode": "artifact", "artifact_channel": "stable"},
  "apps": [{
    "app": "demo",
    "kind": "artifact-bundle",
    "command": "demo",
    "artifact_root": "\$HOME/../cas",
    "install_root": "\$HOME/apps/demo",
    "links": [{"source": "bin/demo", "target": "\$HOME/.local/bin/demo"}],
    "safe_upgrade": {
      "soak_hours": $soak_hours,
      "probes": [{"argv": ["bin/demo"], "timeout_s": 10}]
    }
  }]
}
JSON
}

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

status_json() {
  "$ROOT/bin/host-track" status demo --json > "$tmp/status.json" 2>"$tmp/status.err"
  jq -c 'if type == "array" then .[0] else . end' "$tmp/status.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"

write_registry 1
publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null

# No canary parked: the soak fields must be ABSENT (null), never 0. "No window
# recorded" and "zero seconds elapsed" are opposite readings of the same gate.
before="$(status_json)"
printf '%s\n' "$before" | jq -e '.soak_elapsed_secs == null and .soak_need_secs == null' >/dev/null \
  || fail "no-canary status should report null soak clock, got: $before"
"$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep -qx 'soak=-' \
  || fail "no-canary plain line should render soak=-"

publish_fixture "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho v2'
"$ROOT/bin/host-track" refresh demo >/dev/null
[ -f "$HOST_TRACK_STAMP_DIR/demo.soak.json" ] || fail "soak stamp missing after refresh"

soaking="$(status_json)"
printf '%s\n' "$soaking" | jq -e '.soak_state == "soaking"' >/dev/null \
  || fail "expected a soaking canary, got: $soaking"
printf '%s\n' "$soaking" | jq -e '.soak_need_secs == 3600' >/dev/null \
  || fail "soak_need_secs should be soak_hours*3600, got: $soaking"
printf '%s\n' "$soaking" | jq -e '.soak_elapsed_secs != null and .soak_elapsed_secs >= 0 and .soak_elapsed_secs < 3600' >/dev/null \
  || fail "soak_elapsed_secs should be inside the window, got: $soaking"

# The human line carries both halves, so the reader who never asks for --json
# sees the binding one.
plain="$("$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep '^soak=')"
case "$plain" in
  soak=soaking:*/*:*s/3600s) ;;
  *) fail "plain soak line should carry elapsed/need, got: $plain" ;;
esac

# THE INVARIANT, not the constant: `soak_watch_one` re-reads the window from the
# REGISTRY on every pass, so a window widened after a canary parked binds that
# canary. Reporting the stamp's own copy would print a deadline the flip
# ignores. Widen the registry and the reported need must follow it.
jq -e '.soak_hours == 1' "$HOST_TRACK_STAMP_DIR/demo.soak.json" >/dev/null \
  || fail "fixture expected the stamp to record the original 1h window"
write_registry 2
widened="$(status_json)"
printf '%s\n' "$widened" | jq -e '.soak_need_secs == 7200' >/dev/null \
  || fail "soak_need_secs must follow the registry the gate reads, not the stamp: $widened"

# And the reported window is the one the gate actually applies: at an elapsed
# time inside it, soak-watch still refuses to flip.
write_registry 1
jq --argjson started "$(( $(date +%s) - 60 ))" '.started_epoch = $started | .checks = 99' \
  "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
inside="$(status_json)"
printf '%s\n' "$inside" | jq -e '.soak_elapsed_secs < .soak_need_secs' >/dev/null \
  || fail "fixture should sit inside the window, got: $inside"
out="$("$ROOT/bin/host-track" soak-watch demo)"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "status reported time left but soak-watch flipped anyway: $out"
[ "$(demo)" = v1 ] || fail "soak-watch flipped inside the reported window: $(demo)"

printf 'ok: host-track soak wall clock\n'
