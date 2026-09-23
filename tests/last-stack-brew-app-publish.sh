#!/usr/bin/env bash
# last-stack-brew-app-publish against a fixture Host Track install:
#   - dry-run ships only the configured files and the listed definition subset;
#   - a tampered file, an unstamped current, or a live post-flip watch refuses;
#   - the first public release needs --approve-first-release (exit 3, no upload);
#   - an approved publish runs `gh release create <formula>-v<ver> --latest=false`
#     and opens a tap PR that touches only Formula/<formula>.rb;
#   - --if-needed is a noop once the digest is handled, and never re-uploads a tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin" "$tmp/stamps" "$tmp/cas/manifests" "$tmp/templates" "$tmp/state"
PUB="$ROOT/bin/last-stack-brew-app-publish"

# --- fixture install tree ------------------------------------------------------
digest="$(printf 'd%.0s' {1..64})"
tree="$HOME/.host-track/apps/loom/versions/$digest"
mkdir -p "$tree/dist" "$tree/scripts" "$tree/definitions" "$tree/release"
printf '#!/usr/bin/env bash\necho "loom 0.1.1"\n' > "$tree/dist/loom"
chmod +x "$tree/dist/loom"
printf 'echo impl\n' > "$tree/scripts/loom-implement.sh"
printf '{"graph":"generic"}\n' > "$tree/definitions/generic.json"
printf '{"graph":"tom-factory"}\n' > "$tree/definitions/factory.json"
printf '# public graphs\ngeneric.json\n\n' > "$tree/release/public-definitions.txt"
printf 'Apache License\n' > "$tree/LICENSE"
printf 'notices\n' > "$tree/THIRD_PARTY_NOTICES"
ln -s "versions/$digest" "$HOME/.host-track/apps/loom/current"

(cd "$tree" && find . -type f | sed 's#^\./##' | sort) > "$tmp/files.txt"
jq -Rn --arg d "$digest" --arg root "$tree" '
  [inputs] | {manifest_digest: $d, files: map({path: ., sha256: "", size: 0, mode: 420})}' \
  < "$tmp/files.txt" > "$tmp/m0.json"
while IFS= read -r rel; do
  sha="$(shasum -a 256 "$tree/$rel" | awk '{print $1}')"
  jq --arg p "$rel" --arg s "$sha" '(.files[] | select(.path == $p) | .sha256) = $s' "$tmp/m0.json" > "$tmp/m1.json"
  mv "$tmp/m1.json" "$tmp/m0.json"
done < "$tmp/files.txt"
mv "$tmp/m0.json" "$tmp/cas/manifests/$digest.json"

jq -n --arg d "$digest" --arg r "$tmp/cas" \
  '{app: "loom", manifest_digest: $d, artifact_root: $r, source_oid: "abc123", repo: "EdgeVector/loom"}' \
  > "$tmp/stamps/loom.json"

cat > "$tmp/registry.json" <<'JSON'
{"apps": [{
  "app": "loom", "command": "loom", "install_mode": "artifact",
  "install_root": "$HOME/.host-track/apps/loom",
  "brew_release": {
    "formula": "loom",
    "version_argv": ["dist/loom", "--version"],
    "files": ["dist/loom", "LICENSE", "THIRD_PARTY_NOTICES"],
    "dirs": ["scripts"],
    "subsets": [{"dir": "definitions", "list": "release/public-definitions.txt"}]
  }
}]}
JSON
cat > "$tmp/templates/loom.rb.tmpl" <<'RB'
class Loom < Formula
  version "@VERSION@"
  url "@URL@"
  sha256 "@SHA256@"
end
RB

# --- fakes: gh, forge-git, forge-api ------------------------------------------
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "release list") cat "$GH_TAGS" 2>/dev/null || true ;;
  "release download")
    dir=""; while [ "$#" -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
    [ -f "$GH_PRIOR_MANIFEST" ] && cp "$GH_PRIOR_MANIFEST" "$dir/" ;;
  "release create") : ;;
  "auth token") echo tok ;;
  *) exit 2 ;;
esac
SH
cat > "$tmp/bin/forge-git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FORGE_LOG"
if [ "$1" = clone ]; then
  dest="${@: -1}"
  git init -q "$dest"
  mkdir -p "$dest/Formula"; echo 'class Lastdb; end' > "$dest/Formula/lastdb.rb"
  git -C "$dest" add -A
  git -C "$dest" -c user.name=t -c user.email=t@t commit -q -m init
  exit 0
fi
if [ "$1" = -C ] && [ "$3" = push ]; then exit 0; fi
exec git "$@"
SH
cat > "$tmp/bin/forge-api" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE_LOG"
case "$*" in
  *"/pulls --jq"*) echo 42 ;;
  *"/merge"*) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/forge-git" "$tmp/bin/forge-api"
export GH_LOG="$tmp/gh.log" FORGE_LOG="$tmp/forge.log" GH_TAGS="$tmp/tags.txt" GH_PRIOR_MANIFEST="$tmp/prior.json"
: > "$GH_LOG"; : > "$FORGE_LOG"; : > "$GH_TAGS"

pub() {
  "$PUB" --app loom --registry "$tmp/registry.json" --stamp-dir "$tmp/stamps" \
    --state-dir "$tmp/state" --templates "$tmp/templates" \
    --gh "$tmp/bin/gh" --forge-git "$tmp/bin/forge-git" --forge-api "$tmp/bin/forge-api" "$@"
}

# --- dry run -----------------------------------------------------------------
out="$(pub --dry-run)" || fail "dry-run failed"
printf '%s\n' "$out" | jq -e '.tag == "loom-v0.1.1" and .version == "0.1.1"' >/dev/null \
  || fail "dry-run tag/version wrong: $out"
run_dir="$(printf '%s\n' "$out" | jq -r .run_dir)"
tarball="$run_dir/assets/loom-aarch64-apple-darwin.tar.gz"
tar -tzf "$tarball" | sort > "$tmp/shipped.txt"
printf '%s\n' LICENSE THIRD_PARTY_NOTICES definitions/generic.json dist/loom scripts/loom-implement.sh \
  | sort > "$tmp/expected.txt"
diff "$tmp/expected.txt" "$tmp/shipped.txt" >/dev/null \
  || fail "tarball contents wrong: $(tr '\n' ' ' < "$tmp/shipped.txt")"
tar -tvzf "$tarball" | grep 'dist/loom' | grep -q '^-rwx' || fail "dist/loom lost its exec bit"
grep -q '/releases/download/loom-v0.1.1/loom-aarch64-apple-darwin.tar.gz' "$run_dir/loom.rb" \
  || fail "rendered formula url wrong"
grep -q "sha256 \"$(shasum -a 256 "$tarball" | awk '{print $1}')\"" "$run_dir/loom.rb" \
  || fail "rendered formula sha256 does not match the tarball"
(cd "$run_dir/assets" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || fail "SHA256SUMS.txt does not verify"
[ ! -s "$GH_LOG" ] || fail "dry-run called gh: $(cat "$GH_LOG")"

# --- refusals ------------------------------------------------------------------
cp "$tree/scripts/loom-implement.sh" "$tmp/impl.bak"
echo tampered > "$tree/scripts/loom-implement.sh"
if pub --dry-run >/dev/null 2>"$tmp/tamper.err"; then fail "tampered tree was packaged"; fi
grep -q 'hash mismatch: path=scripts/loom-implement.sh' "$tmp/tamper.err" || fail "tamper refusal unclear"
cp "$tmp/impl.bak" "$tree/scripts/loom-implement.sh"

echo '{}' > "$tmp/stamps/loom.postflip.json"
if pub --dry-run >/dev/null 2>"$tmp/pf.err"; then fail "published during a post-flip watch"; fi
grep -q 'post-flip watch still running' "$tmp/pf.err" || fail "post-flip refusal unclear"
rm "$tmp/stamps/loom.postflip.json"

printf 'missing.json\n' >> "$tree/release/public-definitions.txt"
if pub --dry-run >/dev/null 2>"$tmp/sub.err"; then fail "subset naming a missing definition passed"; fi
grep -q 'names missing.json' "$tmp/sub.err" || fail "subset refusal unclear"
printf '# public graphs\ngeneric.json\n\n' > "$tree/release/public-definitions.txt"

# --- first release needs approval --------------------------------------------------
set +e
pub --publish >/dev/null 2>"$tmp/first.err"
rc=$?
set -e
[ "$rc" = 3 ] || fail "unapproved first release exit $rc, want 3"
grep -q "needs Tom's approval" "$tmp/first.err" || fail "first-release refusal unclear"
grep -q 'release create' "$GH_LOG" && fail "unapproved first release uploaded"

# --- approved publish ----------------------------------------------------------
: > "$GH_LOG"
out="$(pub --publish --approve-first-release)" || fail "approved publish failed"
printf '%s\n' "$out" | jq -e '.tag == "loom-v0.1.1" and .tap_pr == "42"' >/dev/null || fail "publish result: $out"
grep -q '^release create loom-v0.1.1 --repo EdgeVector/homebrew-lastdb .*--latest=false' "$GH_LOG" \
  || fail "gh release create args wrong: $(cat "$GH_LOG")"
grep -q 'push -q origin HEAD:brew/loom-v0.1.1' "$FORGE_LOG" || fail "tap branch not pushed"
grep -q 'repos/EdgeVector/homebrew-lastdb/pulls --jq .number' "$FORGE_LOG" || fail "tap PR not opened"

# --- if-needed: same digest is a noop ----------------------------------------------
: > "$GH_LOG"
pub --publish --if-needed >/dev/null 2>"$tmp/noop.err" || fail "if-needed rerun failed"
grep -q 'already handled; noop' "$tmp/noop.err" || fail "if-needed did not short-circuit"
[ ! -s "$GH_LOG" ] || fail "if-needed noop still called gh"

# --- existing tag with another digest never re-uploads -------------------------
rm -f "$tmp/state/loom.json"
echo loom-v0.1.1 > "$GH_TAGS"
jq -n '{manifest_digest: "other"}' > "$GH_PRIOR_MANIFEST"
: > "$GH_LOG"
if pub --publish >/dev/null 2>"$tmp/dup.err"; then fail "republished an existing tag for a new digest"; fi
grep -q 'bump the app version' "$tmp/dup.err" || fail "same-version refusal unclear"
pub --publish --if-needed >/dev/null 2>&1 || fail "if-needed should not fail on an unbumped version"
grep -q 'release create' "$GH_LOG" && fail "an existing tag was uploaded again"

echo "ok last-stack-brew-app-publish"
