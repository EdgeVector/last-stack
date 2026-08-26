#!/usr/bin/env bash
# Soak RED files one P0 Kind:pr card and does not file again for the same digest.
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
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

: >"$tmp/file-pr.log"
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

digest_good="$(printf 'a%.0s' {1..64})"
digest_bad="$(printf 'b%.0s' {1..64})"
oid_good="$(printf '1%.0s' {1..40})"
oid_bad="$(printf '2%.0s' {1..40})"

export FILE_PR_LOG="$tmp/file-pr.log"
export HOST_TRACK_SOAK_FILE_CARD=1

publish_fixture "$digest_good" "$oid_good" $'#!/usr/bin/env bash\necho ok-v1'
"$ROOT/bin/host-track" install demo >/dev/null

publish_fixture "$digest_bad" "$oid_bad" $'#!/usr/bin/env bash\necho broken\nexit 1'
"$ROOT/bin/host-track" refresh demo >/dev/null || true
[ -d "$HOME/apps/demo/versions/$digest_bad" ] || fail "bad version not staged"
ln -sfn "versions/$digest_bad" "$HOME/apps/demo/canary"

set +e
"$ROOT/bin/host-track" soak-watch demo >/dev/null 2>"$tmp/red1.err"
rc1=$?
set -e
[ "$rc1" -ne 0 ] || fail "soak-watch should fail on RED"
grep -q 'filed P0' "$tmp/red1.err" || fail "first RED did not file a card: $(cat "$tmp/red1.err")"
[ "$(wc -l < "$FILE_PR_LOG" | tr -d ' ')" = 1 ] || fail "expected one file-pr call"
grep -q -- '--priority P0' "$FILE_PR_LOG" || fail "card was not P0"
grep -q 'EdgeVector/demo' "$FILE_PR_LOG" || fail "card repo not from gate_main"
[ "$(demo)" = ok-v1 ] || fail "RED soak changed the live command"

set +e
"$ROOT/bin/host-track" soak-watch demo >/dev/null 2>"$tmp/red2.err"
rc2=$?
set -e
[ "$rc2" -ne 0 ] || fail "second soak-watch should still be RED"
grep -q 'incident card .* already open' "$tmp/red2.err" || fail "second RED re-filed: $(cat "$tmp/red2.err")"
[ "$(wc -l < "$FILE_PR_LOG" | tr -d ' ')" = 1 ] || fail "second RED called file-pr again"

printf 'ok: soak RED files one P0 card\n'
