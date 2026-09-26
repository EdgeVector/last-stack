#!/usr/bin/env bash
set -euo pipefail

# An artifact that adds a command AND its config/host-track/apps.json links[]
# entry in one commit must get the PATH name from the install that delivers it.
# host-track resolves $REGISTRY from its own root, which during a self-flip is
# the OUTGOING tree, so the new entry used to be invisible to the flip applying
# it: the file installed, the registry installed, and no PATH name appeared
# until a later flip happened to carry it. Measured on EdgeVector/last-stack#268
# (papercut-host-track-applies-links-from-the-outgoing-registry-so-a-new-path-name-lands-one-flip-late-20260926).

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

# The HOST registry knows only the original command. `demo-added` appears for the
# first time in the artifact's OWN registry, exactly like a bin plus its links[]
# entry landing in one commit.
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
        {"source": "bin/demo", "target": "$HOME/.local/bin/demo"}
      ],
      "notes": "incoming-registry links test"
    }
  ]
}
JSON

# publish_fixture <digest> <oid> <ship_added_bin> <declare_added_link>
#   ship_added_bin=1     -> the tree contains bin/demo-added
#   declare_added_link=1 -> the tree's OWN registry also declares its links[] entry
publish_fixture() {
  local digest="$1" oid="$2" ship_added="$3" declare_added="$4"
  local tree="$tmp/tree" manifest files rel sha size blob
  rm -rf "$tree"
  mkdir -p "$tree/bin" "$tree/config/host-track"
  printf '#!/usr/bin/env bash\necho demo-%s\n' "${digest:0:1}" > "$tree/bin/demo"
  chmod +x "$tree/bin/demo"
  if [ "$ship_added" = 1 ]; then
    printf '#!/usr/bin/env bash\necho added-ok\n' > "$tree/bin/demo-added"
    chmod +x "$tree/bin/demo-added"
  fi
  # The artifact carries the same registry shape last-stack ships.
  if [ "$declare_added" = 1 ]; then
    jq -n '{apps: [{app: "demo", links: [
      {source: "bin/demo", target: "$HOME/.local/bin/demo"},
      {source: "bin/demo-added", target: "$HOME/.local/bin/demo-added"}
    ]}]}' > "$tree/config/host-track/apps.json"
  else
    jq -n '{apps: [{app: "demo", links: [
      {source: "bin/demo", target: "$HOME/.local/bin/demo"}
    ]}]}' > "$tree/config/host-track/apps.json"
  fi

  files="[]"
  while IFS= read -r rel; do
    sha="$(shasum -a 256 "$tree/$rel" | awk '{print $1}')"
    size="$(wc -c < "$tree/$rel" | tr -d ' ')"
    blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
    mkdir -p "$(dirname "$blob")"
    cp "$tree/$rel" "$blob"
    files="$(printf '%s' "$files" | jq -c \
      --arg path "$rel" --arg sha "$sha" --argjson size "$size" \
      --argjson mode "$([ -x "$tree/$rel" ] && echo 493 || echo 420)" \
      '. + [{path: $path, sha256: $sha, size: $size, mode: $mode}]')"
  done < <(cd "$tree" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

  mkdir -p "$tmp/cas/channels/demo" "$tmp/cas/manifests"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n --arg digest "$digest" --arg oid "$oid" --argjson files "$files" \
    '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-09-26T00:00:00Z",
      files: $files, manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/demo/stable.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
digest_bad="$(printf 'c%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
oid_bad="$(printf '3%.0s' {1..40})"

# v1: no demo-added anywhere. This is the OUTGOING tree for the flip under test.
publish_fixture "$digest_one" "$oid_one" 0 0
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = "demo-a" ] || fail "v1 did not install"
[ ! -e "$HOME/.local/bin/demo-added" ] || fail "v1 created a link it never declared"

# v2 ships the new command AND declares its link in its own registry. The host
# registry is untouched, so the outgoing declarations still name only bin/demo.
publish_fixture "$digest_two" "$oid_two" 1 1
"$ROOT/bin/host-track" refresh demo >/dev/null
[ "$(demo)" = "demo-b" ] || fail "v2 did not activate"

[ -L "$HOME/.local/bin/demo-added" ] \
  || fail "the flip that delivered the links[] entry did not create its PATH name"
[ "$(demo-added)" = "added-ok" ] \
  || fail "the new PATH name does not resolve into the active tree"
[ "$(readlink "$HOME/.local/bin/demo-added")" = "$HOME/apps/demo/current/bin/demo-added" ] \
  || fail "the new PATH name does not point through current/"

# The host registry itself must be untouched: the fix reads the incoming tree,
# it does not write back. Without this a green assertion above could come from
# the fixture having been rewritten rather than from the flip.
jq -e '[.apps[0].links[].source] == ["bin/demo"]' "$HOST_TRACK_REGISTRY" >/dev/null \
  || fail "the host registry was modified; the incoming read must not write back"

# Rolling back must return to the declarations of the tree being restored, not
# keep applying the newer tree's. A link whose source does not exist in the
# rolled-back tree is exactly the case that used to die after the symlink moved.
"$ROOT/bin/host-track" rollback demo >/dev/null
[ "$(demo)" = "demo-a" ] || fail "rollback did not reactivate v1"
[ ! -e "$HOME/.local/bin/demo-added" ] \
  || fail "rollback left a PATH name the restored tree does not declare"

# A tree that declares a link source it does not contain must be refused BEFORE
# the cutover, so the failure lands on the old tree instead of half-linking.
publish_fixture "$digest_bad" "$oid_bad" 0 1
if "$ROOT/bin/host-track" refresh demo >/dev/null 2>"$tmp/bad.err"; then
  fail "a tree declaring a missing link source was activated"
fi
# Assert the CONSEQUENCE before the wording. Without the pre-cutover check the
# refresh still exits non-zero -- it dies inside install_artifact_links -- but
# only after current moved, which is the half-linked state the check exists to
# prevent, so that is what the probe should name.
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_one" ] \
  || fail "refused activation still moved current"
[ "$(demo)" = "demo-a" ] || fail "refused activation changed the live command"
grep -q "which that tree does not contain" "$tmp/bad.err" \
  || fail "refusal did not name the missing declared source (got: $(cat "$tmp/bad.err"))"

printf 'ok: host-track applies links[] from the tree it activates\n'
