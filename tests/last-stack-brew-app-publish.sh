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
    dir="" pat=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = --dir ] && dir="$2"
      [ "$1" = --pattern ] && pat="$2"
      shift
    done
    if [ -f "$GH_PRIOR_MANIFEST" ]; then cp "$GH_PRIOR_MANIFEST" "$dir/$pat"; else exit 1; fi ;;
  "release create") : ;;
  "auth token") echo tok ;;
  *) exit 2 ;;
esac
SH
# The tap clone uses plain git against LAST_STACK_FORGE_BASE: point it at a
# local bare repo. (last-stack-forge-git cannot clone; it wraps an existing repo.)
mkdir -p "$tmp/forge/EdgeVector"
git init -q --bare "$tmp/forge/EdgeVector/homebrew-lastdb.git"
git init -q "$tmp/seed"
mkdir -p "$tmp/seed/Formula"; echo 'class Lastdb; end' > "$tmp/seed/Formula/lastdb.rb"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/seed" push -q "$tmp/forge/EdgeVector/homebrew-lastdb.git" HEAD:main
export LAST_STACK_FORGE_BASE="file://$tmp/forge"
cat > "$tmp/bin/forge-git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FORGE_LOG"
[ "$1" = -C ] || { echo "forge-git needs -C <repo>" >&2; exit 2; }
exec git "$@"
SH
cat > "$tmp/bin/forge-api" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE_LOG"
case "$*" in
  *"/contents/Formula/"*) [ -f "$TAP_MAIN_FORMULA" ] && base64 < "$TAP_MAIN_FORMULA" | tr -d '\n' ; exit 0 ;;
  *"/pulls/main/"*) exit 1 ;;
  *"/pulls --jq"*) echo 42 ;;
  *"/merge"*) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/forge-git" "$tmp/bin/forge-api"
export GH_LOG="$tmp/gh.log" FORGE_LOG="$tmp/forge.log" GH_TAGS="$tmp/tags.txt" GH_PRIOR_MANIFEST="$tmp/prior.json"
export TAP_MAIN_FORMULA="$tmp/tap-main-loom.rb"
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
first_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
sleep 1
out2="$(pub --dry-run)" || fail "second dry-run failed"
second_sha="$(printf '%s\n' "$out2" | jq -r .tarball_sha256)"
[ "$first_sha" = "$second_sha" ] || fail "tarball is not reproducible: $first_sha vs $second_sha"

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
git -C "$tmp/forge/EdgeVector/homebrew-lastdb.git" show brew/loom-v0.1.1:Formula/loom.rb | grep -q 'loom-v0.1.1' \
  || fail "pushed tap branch lacks the rendered formula"
[ "$(git -C "$tmp/forge/EdgeVector/homebrew-lastdb.git" diff --name-only main brew/loom-v0.1.1)" = "Formula/loom.rb" ] \
  || fail "tap branch touches more than Formula/loom.rb"
grep -q 'repos/EdgeVector/homebrew-lastdb/pulls --jq .number' "$FORGE_LOG" || fail "tap PR not opened"

# --- if-needed: same digest is a noop ----------------------------------------------
: > "$GH_LOG"
pub --publish --if-needed >/dev/null 2>"$tmp/noop.err" || fail "if-needed rerun failed"
grep -q 'already handled; noop' "$tmp/noop.err" || fail "if-needed did not short-circuit"
[ ! -s "$GH_LOG" ] || fail "if-needed noop still called gh"

# --- resume: the release exists for this digest but the tap PR never opened ------
rm -f "$tmp/state/loom.json"
git -C "$tmp/forge/EdgeVector/homebrew-lastdb.git" branch -D brew/loom-v0.1.1 >/dev/null
echo loom-v0.1.1 > "$GH_TAGS"
cp "$run_dir/assets/loom-aarch64-apple-darwin.manifest.json" "$GH_PRIOR_MANIFEST"
jq --arg d "$digest" '.manifest_digest = $d' "$GH_PRIOR_MANIFEST" > "$tmp/pm.json" && mv "$tmp/pm.json" "$GH_PRIOR_MANIFEST"
: > "$GH_LOG"; : > "$FORGE_LOG"
pub --publish >/dev/null 2>"$tmp/resume.err" || { cat "$tmp/resume.err" >&2; fail "resume run failed"; }
grep -q 'release existed, formula did not' "$tmp/resume.err" || fail "resume did not open the missing tap PR"
grep -q 'release create' "$GH_LOG" && fail "resume re-uploaded the release"
released_sha="$(jq -r .tarball_sha256 "$GH_PRIOR_MANIFEST")"
git -C "$tmp/forge/EdgeVector/homebrew-lastdb.git" show brew/loom-v0.1.1:Formula/loom.rb | grep -q "$released_sha" \
  || fail "resumed formula does not carry the RELEASED tarball sha256"
# Tap main already current: no PR.
git -C "$tmp/forge/EdgeVector/homebrew-lastdb.git" show brew/loom-v0.1.1:Formula/loom.rb > "$TAP_MAIN_FORMULA"
rm -f "$tmp/state/loom.json"; : > "$FORGE_LOG"
pub --publish >/dev/null 2>"$tmp/current.err" || fail "rerun with a current tap failed"
grep -q 'tap formula for loom-v0.1.1: current' "$tmp/current.err" || fail "current tap formula not recognized"
grep -q '/pulls --jq' "$FORGE_LOG" && fail "opened a PR although tap main is current"
rm -f "$TAP_MAIN_FORMULA"

# --- existing tag with another digest never re-uploads -------------------------
rm -f "$tmp/state/loom.json"
echo loom-v0.1.1 > "$GH_TAGS"
jq -n '{manifest_digest: "other"}' > "$GH_PRIOR_MANIFEST"
: > "$GH_LOG"
if pub --publish >/dev/null 2>"$tmp/dup.err"; then fail "republished an existing tag for a new digest"; fi
grep -q 'bump the app version' "$tmp/dup.err" || fail "same-version refusal unclear"
pub --publish --if-needed >/dev/null 2>&1 || fail "if-needed should not fail on an unbumped version"
grep -q 'release create' "$GH_LOG" && fail "an existing tag was uploaded again"

# --- the shipped templates render to valid Ruby --------------------------------
for tmpl in "$ROOT"/templates/homebrew/*.rb.tmpl; do
  rendered="$tmp/$(basename "$tmpl" .tmpl)"
  sed -e 's/@VERSION@/0.1.1/' -e 's#@URL@#https://example.invalid/x.tar.gz#' \
    -e "s/@SHA256@/$(printf 'a%.0s' {1..64})/" "$tmpl" > "$rendered"
  if grep -q '@[A-Z0-9_]*@' "$rendered"; then fail "$tmpl has a placeholder the publisher does not fill"; fi
  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$rendered" >/dev/null || fail "$tmpl renders to invalid Ruby"
  fi
done
# Every app with brew_release config has a template.
jq -r '.apps[] | select(.brew_release | type == "object") | (.brew_release.formula // .app)' \
  "$ROOT/config/host-track/apps.json" | while IFS= read -r f; do
  [ -f "$ROOT/templates/homebrew/$f.rb.tmpl" ] || fail "brew_release formula $f has no template"
done

echo "ok last-stack-brew-app-publish"
