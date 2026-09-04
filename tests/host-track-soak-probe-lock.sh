#!/usr/bin/env bash
# soak-watch must not probe a canary tree that a concurrent install may be
# restaging: with the app's install lock held by a live process, the tick
# defers (rc 0, no soak_red stamp, no card). With the lock free, the same
# healthy canary probes GREEN and soaks normally.
# Regression for 2026-09-04: a force-if-stale restage raced soak-watch and a
# healthy brain digest was rejected as soak RED, spawning a spurious P0 + heal.
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
export HOST_TRACK_FILE_PR="$tmp/bin/last-stack-kanban-file-pr"
export HOST_TRACK_SOAK_HEAL=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

: >"$tmp/file-pr.log"
export FILE_PR_LOG="$tmp/file-pr.log"
cat >"$tmp/bin/last-stack-kanban-file-pr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FILE_PR_LOG:?}"
cat >/dev/null
echo "filed $1"
SH
chmod +x "$tmp/bin/last-stack-kanban-file-pr"

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

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {"install_mode": "artifact", "artifact_channel": "stable"},
  "apps": [{
    "app": "demo",
    "kind": "artifact-bundle",
    "command": "demo",
    "gate_main": "lastdb:///demo#main",
    "artifact_root": "$HOME/../cas",
    "install_root": "$HOME/apps/demo",
    "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
    "safe_upgrade": {
      "soak_hours": 1,
      "probes": [{"argv": ["bin/demo"], "timeout_s": 10, "output_matches": "ok"}]
    }
  }]
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

digest_v1="$(printf 'a%.0s' {1..64})"
digest_v2="$(printf 'b%.0s' {1..64})"
oid_v1="$(printf '1%.0s' {1..40})"
oid_v2="$(printf '2%.0s' {1..40})"

publish_fixture "$digest_v1" "$oid_v1" $'#!/usr/bin/env bash\necho ok-v1'
"$ROOT/bin/host-track" install demo >/dev/null

# Park a healthy v2 canary.
publish_fixture "$digest_v2" "$oid_v2" $'#!/usr/bin/env bash\necho ok-v2'
"$ROOT/bin/host-track" refresh demo >/dev/null
[ -L "$HOME/apps/demo/canary" ] || fail "canary not parked"

# 1) Lock held by a live process → soak-watch defers, never RED.
lock="$HOME/.host-track/locks/install-demo.lock.d"
mkdir -p "$lock"
printf '%s\n' "$$" > "$lock/pid"
set +e
HOST_TRACK_SOAK_LOCK_WAIT_S=1 "$ROOT/bin/host-track" soak-watch demo \
  > "$tmp/defer.out" 2> "$tmp/defer.err"
rc=$?
set -e
rm -rf "$lock"
[ "$rc" -eq 0 ] || fail "locked soak-watch should defer with rc 0 (rc=$rc): $(cat "$tmp/defer.err")"
grep -q 'deferred (install in progress)' "$tmp/defer.out" \
  || fail "locked soak-watch did not report deferral: $(cat "$tmp/defer.out" "$tmp/defer.err")"
if [ -f "$HOST_TRACK_STAMP_DIR/demo.soak.json" ]; then
  st="$(jq -r '.status' "$HOST_TRACK_STAMP_DIR/demo.soak.json")"
  [ "$st" != "soak_red" ] || fail "locked soak-watch marked soak_red"
fi
[ ! -s "$FILE_PR_LOG" ] || fail "locked soak-watch filed a card: $(cat "$FILE_PR_LOG")"

# 2) Lock free → the same canary probes GREEN and the soak advances.
"$ROOT/bin/host-track" soak-watch demo > "$tmp/free.out" 2> "$tmp/free.err" \
  || fail "unlocked soak-watch failed: $(cat "$tmp/free.err")"
grep -q 'soak pending' "$tmp/free.out" || fail "unlocked soak-watch did not soak: $(cat "$tmp/free.out")"
[ "$(jq -r '.status' "$HOST_TRACK_STAMP_DIR/demo.soak.json")" = "soaking" ] \
  || fail "soak stamp not soaking after green probe"
[ -s "$HOST_TRACK_STAMP_DIR/soak-history/last-probe-demo.log" ] \
  || fail "probe transcript not kept"
[ ! -d "$lock" ] || fail "soak-watch leaked its install lock"

printf 'ok: soak-watch defers under a held install lock and soaks when free\n'
