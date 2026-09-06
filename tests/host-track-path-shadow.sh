#!/usr/bin/env bash
set -euo pipefail

# `host-track check` verifies that the installed artifact tree is intact. It did
# not verify that the tree is what a caller actually RUNS. `install_artifact_links`
# replaces a real file sitting on a PATH target, but only for targets the manifest
# DECLARES, so a command links[] never named is not merely unhealed — it is never
# looked at. A checkout-era copy left in ~/.local/bin then shadows the managed
# command forever, because ~/.local/bin precedes the install tree on PATH.
#
# Measured on the live host 2026-09-06: last-stack had 43/43 declared targets
# healthy and 13 undeclared names still shadowed, one of them a symlink into an
# install root abandoned on 2026-08-30. `host-track check last-stack` printed
# "ok" throughout.
#
# The report must never fail the command: `check` gates last-stack-class-a-heal,
# last-stack-routine-read and the artifact proof, and a shadow is a stale-install
# defect rather than a broken artifact.

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

write_registry() {
  # $1 = extra links[] entries (JSON array text)
  cat > "$HOST_TRACK_REGISTRY" <<JSON
{
  "defaults": { "install_mode": "artifact", "artifact_channel": "stable" },
  "apps": [
    {
      "app": "shadowdemo",
      "kind": "artifact-bundle",
      "command": "sd-linked",
      "artifact_root": "\$HOME/../cas",
      "install_root": "\$HOME/apps/shadowdemo",
      "links": $1,
      "notes": "PATH shadow detection test"
    }
  ]
}
JSON
}

declared_only='[{"source": "bin/sd-linked", "target": "$HOME/.local/bin/sd-linked"}]'
declared_all='[{"source": "bin/sd-linked", "target": "$HOME/.local/bin/sd-linked"},
               {"source": "bin/sd-orphan", "target": "$HOME/.local/bin/sd-orphan"},
               {"source": "bin/sd-dead", "target": "$HOME/.local/bin/sd-dead"}]'

publish_fixture() {
  local digest="$1" oid="$2" manifest
  local -a paths=(sd-linked sd-orphan sd-dead)
  local jq_files='[]' name sha size blob
  mkdir -p "$tmp/cas/channels/shadowdemo" "$tmp/cas/manifests"
  for name in "${paths[@]}"; do
    printf '#!/usr/bin/env bash\necho %s-managed\n' "$name" > "$tmp/payload-$name"
    sha="$(shasum -a 256 "$tmp/payload-$name" | awk '{print $1}')"
    size="$(wc -c < "$tmp/payload-$name" | tr -d ' ')"
    blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
    mkdir -p "$(dirname "$blob")"
    cp "$tmp/payload-$name" "$blob"
    jq_files="$(printf '%s' "$jq_files" | jq \
      --arg path "bin/$name" --arg sha "$sha" --argjson size "$size" \
      '. + [{path: $path, sha256: $sha, size: $size, mode: 493}]')"
  done
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n --arg digest "$digest" --arg oid "$oid" --argjson files "$jq_files" \
    '{schema_version: 1, app: "shadowdemo", repo: "EdgeVector/shadowdemo",
      source_oid: $oid, platform: "test-arm64", created_at: "2026-09-06T00:00:00Z",
      files: $files, manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/shadowdemo/stable.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"

write_registry "$declared_only"
publish_fixture "$digest_one" "$oid_one"
"$ROOT/bin/host-track" install shadowdemo >/dev/null 2>"$tmp/install.err" \
  || fail "fixture install failed: $(cat "$tmp/install.err")"

# sd-linked is declared, so install owns it: PATH resolves into the active tree.
[ -L "$HOME/.local/bin/sd-linked" ] || fail "declared link is not a symlink"

# sd-orphan: a checkout-era REAL FILE that no links[] entry names.
printf '#!/usr/bin/env bash\necho sd-orphan-stale\n' > "$HOME/.local/bin/sd-orphan"
chmod +x "$HOME/.local/bin/sd-orphan"

# sd-dead: a symlink into an install root this app abandoned. It is a symlink,
# it resolves, and it is executable — everything except pointing at the tree
# host-track verified. This is the shape that survived on the live host.
mkdir -p "$HOME/oldapps/shadowdemo/current/bin"
printf '#!/usr/bin/env bash\necho sd-dead-stale\n' > "$HOME/oldapps/shadowdemo/current/bin/sd-dead"
chmod +x "$HOME/oldapps/shadowdemo/current/bin/sd-dead"
ln -s "$HOME/oldapps/shadowdemo/current/bin/sd-dead" "$HOME/.local/bin/sd-dead"

[ "$(sd-orphan)" = sd-orphan-stale ] || fail "fixture shadow does not win on PATH"
[ "$(sd-dead)" = sd-dead-stale ] || fail "fixture dead-root link does not win on PATH"

# check must still succeed: reporting a shadow may not red the fleet gates.
"$ROOT/bin/host-track" check shadowdemo >"$tmp/check.out" 2>"$tmp/check.err" \
  || fail "PATH shadow made check fail; it gates class-a-heal and routine-read"
grep -q 'shadowdemo ok' "$tmp/check.out" \
  || fail "check did not report ok (got: $(cat "$tmp/check.out"))"

# ...and it must name both shadows.
grep -q 'PATH shadow: sd-orphan runs' "$tmp/check.err" \
  || fail "check did not report the undeclared real-file shadow (got: $(cat "$tmp/check.err"))"
grep -q 'PATH shadow: sd-dead runs' "$tmp/check.err" \
  || fail "check did not report the symlink into an abandoned install root (got: $(cat "$tmp/check.err"))"
grep -q '2 managed command(s) shadowed on PATH' "$tmp/check.err" \
  || fail "check did not summarise the shadow count (got: $(cat "$tmp/check.err"))"

# The healthy declared link must NOT be reported. Without this a detector that
# flags everything would pass every assertion above.
if grep -q 'PATH shadow: sd-linked' "$tmp/check.err"; then
  fail "check reported a correctly linked command as a shadow"
fi

printf 'ok: check reports PATH shadows without failing\n'

# ── the repair: declaring the names heals them through the existing link path ──
write_registry "$declared_all"
"$ROOT/bin/host-track" refresh --force --activate shadowdemo >/dev/null 2>"$tmp/refresh.err" \
  || fail "refresh with the new links failed: $(cat "$tmp/refresh.err")"

[ -L "$HOME/.local/bin/sd-orphan" ] || fail "declared orphan was not replaced by a symlink"
[ -L "$HOME/.local/bin/sd-dead" ] || fail "declared dead-root link was not repointed"
[ "$(sd-orphan)" = sd-orphan-managed ] || fail "PATH still runs the stale orphan copy"
[ "$(sd-dead)" = sd-dead-managed ] || fail "PATH still runs the abandoned install root"
[ -n "$(find "$HOME/.local/bin" -name 'sd-orphan.bak-pre-artifact-*' -print -quit)" ] \
  || fail "the replaced real file was not backed up"

"$ROOT/bin/host-track" check shadowdemo >"$tmp/check2.out" 2>"$tmp/check2.err" \
  || fail "check failed after the repair: $(cat "$tmp/check2.err")"
if grep -q 'PATH shadow' "$tmp/check2.err"; then
  fail "check still reports a shadow after the repair (got: $(cat "$tmp/check2.err"))"
fi

printf 'ok: declaring a shadowed name in links[] heals it and clears the report\n'
