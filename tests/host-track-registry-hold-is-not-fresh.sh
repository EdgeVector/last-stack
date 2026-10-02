#!/usr/bin/env bash
# A registry HOLD must not also render `freshness=fresh` while a published
# artifact sits past the install.
#
# papercut-host-track-status-renders-stale-false-fresh-when-gate-head-is-unreadable-20261001
# measured six of seventeen apps (brain, situations, routines, lastsecrets,
# search, lastdb-browser) reading `gate_head=- stale=false freshness=fresh`
# while `routines` was three merged, published commits behind main. The chain:
# `no-proved-row` clears channel_oid, an empty channel_oid suppresses
# `main_unpublished`, and a suppressed `main_unpublished` leaves `freshness`
# at its `fresh` default. Every field is individually defensible and the row
# as a whole says the install is current when it is not.
#
# `stale` keeps its documented meaning (the install IS the newest pair anyone
# proved, so a hold is not stale and refresh must not churn). Only `freshness`
# and `pin_behind_oid` change, and only when a published head is genuinely
# ahead of the installed tree — a hold that sits ON the published head is
# still `fresh`, which is the negative half this test pins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_PROBE_SKIP=1
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
export HOST_TRACK_TEST_MAIN_OID="$oid_one"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = status ]; then
  jq -n --arg oid "$HOST_TRACK_TEST_MAIN_OID" '{refs:[{name:"refs/heads/main",oid:$oid}]}'; exit 0
fi
if [ "${1:-}" = ref ]; then
  printf '%s\t%s\t%s\n' "$HOST_TRACK_TEST_MAIN_OID" "refs/heads/${3:-main}" point; exit 0
fi
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;; --channel) channel="$2"; shift 2 ;; --root) root="$2"; shift 2 ;;
    --json|--promote) shift ;; --repo|--oid|--context|--manifest) shift 2 ;; *) exit 2 ;;
  esac
done
cat "$root/channels/$app/$channel.json"
SH
chmod +x "$tmp/bin/lastgit"

# Same fake resolver as tests/host-track-registry-pin.sh: RESOLVE_NO_ROW=1 is
# the hold this test is about.
cat > "$tmp/bin/lastdb" <<SH
#!/usr/bin/env bash
[ "\$1" = app ] && [ "\$2" = resolve ] || { echo unknown >&2; exit 2; }
[ "\$3" = --help ] && { echo usage; exit 0; }
app="\$3"
if [ "\${RESOLVE_NO_ROW:-0}" = 1 ]; then
  echo "error: no next row for app '\$app' was proved with lastdb 0.23.3-1-gx; run \\\`brew upgrade lastdb\\\`" >&2; exit 1
fi
sha="\$(jq -r --arg a "\$app" '.[\$a] // empty' "$tmp/resolve.json")"
[ -n "\$sha" ] || { echo "error: app '\$app' is not in the next index" >&2; exit 1; }
jq -n --arg a "\$app" --arg sha "\$sha" '{app_id:\$a, channel:"next", sha:\$sha, app_version:"1.0.0", lastdb_version:"0.23.3-1-gx", proof_run:"run-x", source:"x"}'
SH
chmod +x "$tmp/bin/lastdb"
printf '{"demo":"%s"}\n' "$oid_one" >"$tmp/resolve.json"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "registry_channel": "next",
    "registry_index": "http://forge.test/registry"
  },
  "apps": [
    {
      "app": "demo", "kind": "artifact-bundle", "command": "demo", "install_mode": "artifact",
      "gate": "lastgit", "gate_main": "lastdb:///demo#main", "track_gate_main": false,
      "artifact_root": "$HOME/../cas", "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "registry hold freshness fixture"
    }
  ]
}
JSON

publish_fixture() {
  local app="$1" digest="$2" oid="$3" content="$4" payload sha size blob manifest
  payload="$tmp/payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/$app" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n --arg app "$app" --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: $app, repo: $app, source_oid: $oid, platform: "test-arm64",
      created_at: "2026-09-20T00:00:00Z",
      files: [{path: ("bin/" + $app), sha256: $sha, size: $size, mode: 493}], manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/$app/stable.json"
}

d1="$(printf 'a%.0s' {1..64})"; d2="$(printf 'b%.0s' {1..64})"

publish_fixture demo "$d1" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "fixture install did not run"

# NEGATIVE HALF: a hold whose install IS the published head is genuinely
# current. This must stay `fresh`, or the fix is a blanket pessimism that
# reports every post-upgrade hold as lag.
st="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "no-proved-row"' >/dev/null \
  || fail "fixture did not reach the hold: $st"
printf '%s\n' "$st" | jq -e '.freshness == "fresh" and .pin_behind_oid == null' >/dev/null \
  || fail "a hold ON the published head must stay fresh with no pin_behind: $st"

# POSITIVE HALF: the channel publishes oid_two, the install is still v1, and
# the registry still proves nothing for this node build. The host holds, and
# the row must say so instead of saying `fresh`.
publish_fixture demo "$d2" "$oid_two" $'#!/usr/bin/env bash\necho v2'
export HOST_TRACK_TEST_MAIN_OID="$oid_two"
st="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "no-proved-row"' >/dev/null \
  || fail "hold state lost once the channel moved: $st"
printf '%s\n' "$st" | jq -e '.freshness != "fresh"' >/dev/null \
  || fail "a hold behind a published artifact still reads fresh: $st"
printf '%s\n' "$st" | jq -e '.freshness == "soft_stale"' >/dev/null \
  || fail "a hold behind a published artifact must be soft lag, not hard_broken: $st"
# `stale` is load-bearing for refresh and force-fresh-if-stale: flipping it
# would restage every tick against a pair nobody proved
# (papercut-force-fresh-guard-forces-a-restage-every-tick-while-a-canary-soaks-20260926).
printf '%s\n' "$st" | jq -e '.stale == false' >/dev/null \
  || fail "the hold became stale; refresh would churn against an unproved pair: $st"
# Name what the host is waiting on, so the wait is legible.
printf '%s\n' "$st" | jq -e --arg oid "$oid_two" '.pin_behind_oid == $oid' >/dev/null \
  || fail "the published head the hold is behind is not reported: $st"
# Same enum guard tests/host-track-registry-pin.sh asserts: 7 sites branch on
# the literal values, so a fourth token takes the silent `else` in all of them.
printf '%s\n' "$st" | jq -e '. as $r | (["fresh","soft_stale","hard_broken"] | index($r.freshness)) != null' >/dev/null \
  || fail "the hold invented a new freshness value: $st"

# Still a hold: refresh must not install the unproved published artifact.
set +e
RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/hold.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "hold did not return 75 (rc=$rc): $(cat "$tmp/hold.err")"
[ "$(demo)" = v1 ] || fail "the hold installed an unproved artifact"

printf 'PASS host-track-registry-hold-is-not-fresh\n'
