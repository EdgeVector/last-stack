#!/usr/bin/env bash
set -euo pipefail

# `check` proves the installed TREE and never asked whether the PATH names the
# registry declares exist. report_path_shadows skips an absent name (it resolves
# nowhere) and verify_active_artifact only walks manifest.files[]. Measured
# 2026-09-26 on last-stack: 1 of 93 declared targets absent for an hour, `check`
# silent on both streams
# (papercut-host-track-check-never-verifies-a-declared-links-target-exists-20260926).
#
# Report, never fail: a link problem is a stale-install defect, and `check` gates
# last-stack-class-a-heal, routine-read and the artifact proof.

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
      "links": [
        {"source": "bin/demo", "target": "$HOME/.local/bin/demo"},
        {"source": "bin/demo-extra", "target": "$HOME/.local/bin/demo-extra"}
      ],
      "notes": "declared-link detector test"
    }
  ]
}
JSON

digest="$(printf 'a%.0s' {1..64})"
oid="$(printf '1%.0s' {1..40})"
tree="$tmp/tree"
mkdir -p "$tree/bin"
printf '#!/usr/bin/env bash\necho demo-v1\n' > "$tree/bin/demo"
printf '#!/usr/bin/env bash\necho extra-v1\n' > "$tree/bin/demo-extra"
chmod +x "$tree/bin/demo" "$tree/bin/demo-extra"

files="[]"
while IFS= read -r rel; do
  sha="$(shasum -a 256 "$tree/$rel" | awk '{print $1}')"
  size="$(wc -c < "$tree/$rel" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")"
  cp "$tree/$rel" "$blob"
  files="$(printf '%s' "$files" | jq -c --arg path "$rel" --arg sha "$sha" --argjson size "$size" \
    '. + [{path: $path, sha256: $sha, size: $size, mode: 493}]')"
done < <(cd "$tree" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
mkdir -p "$tmp/cas/channels/demo" "$tmp/cas/manifests"
jq -n --arg digest "$digest" --arg oid "$oid" --argjson files "$files" \
  '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
    platform: "test-arm64", created_at: "2026-09-26T00:00:00Z",
    files: $files, manifest_digest: $digest}' > "$tmp/cas/manifests/$digest.json"
cp "$tmp/cas/manifests/$digest.json" "$tmp/cas/channels/demo/stable.json"

"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = "demo-v1" ] || fail "install did not activate"
[ -L "$HOME/.local/bin/demo-extra" ] || fail "install did not create the second declared name"

# Healthy: neither report fires.
"$ROOT/bin/host-track" check demo >"$tmp/ok.out" 2>"$tmp/ok.err" \
  || fail "healthy install failed check: $(cat "$tmp/ok.err")"
grep -q "declared PATH name" "$tmp/ok.err" \
  && fail "healthy install reported a missing declared name: $(cat "$tmp/ok.err")"

# One declared target deleted by hand. The TREE is untouched, so every existing
# check still passes -- which is the whole point of this one.
rm -f "$HOME/.local/bin/demo-extra"
"$ROOT/bin/host-track" check demo >"$tmp/gone.out" 2>"$tmp/gone.err" \
  || fail "a missing PATH name must not fail check (it is a stale-install defect)"
grep -q "demo declared PATH name missing: $HOME/.local/bin/demo-extra (source bin/demo-extra)" "$tmp/gone.err" \
  || fail "check did not name the missing declared target (got: $(cat "$tmp/gone.err"))"
grep -q "1 declared PATH name(s) not installed; repair: host-track refresh --force demo" "$tmp/gone.err" \
  || fail "check did not print the repair (got: $(cat "$tmp/gone.err"))"

# A target that exists but points at somebody else's file is not "present".
# report_path_shadows cannot make this call for a name that is in neither
# current/bin nor current/dist, and here it is in bin/ only by coincidence.
printf '#!/usr/bin/env bash\necho foreign\n' > "$tmp/foreign"
chmod +x "$tmp/foreign"
ln -s "$tmp/foreign" "$HOME/.local/bin/demo-extra"
"$ROOT/bin/host-track" check demo >"$tmp/foreign.out" 2>"$tmp/foreign.err" \
  || fail "a foreign PATH name must not fail check"
grep -q "demo declared PATH name $HOME/.local/bin/demo-extra points outside this install: $tmp/foreign" \
  "$tmp/foreign.err" \
  || fail "check did not name the foreign target (got: $(cat "$tmp/foreign.err"))"

# The repair the message names must actually repair, and the report must then
# fall silent rather than latch. Measured 2026-09-26: `refresh --activate` and a
# plain `refresh` both leave the name missing, because install_artifact_links
# runs on a CUTOVER and an unchanged current never reaches it. Only --force and
# install repair it, which is why both messages here name --force.
rm -f "$HOME/.local/bin/demo-extra"
"$ROOT/bin/host-track" refresh --activate demo >/dev/null 2>&1 || true
[ ! -e "$HOME/.local/bin/demo-extra" ] \
  || fail "refresh --activate now repairs a link; both messages should name it again"
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>&1 || true
"$ROOT/bin/host-track" check demo >"$tmp/healed.out" 2>"$tmp/healed.err" \
  || fail "healed install failed check: $(cat "$tmp/healed.err")"
grep -q "declared PATH name" "$tmp/healed.err" \
  && fail "healed install still reported a missing declared name: $(cat "$tmp/healed.err")"
[ "$(demo-extra)" = "extra-v1" ] || fail "repair did not restore the declared name"

printf 'ok: check reports a declared links[] target that is absent or foreign\n'
