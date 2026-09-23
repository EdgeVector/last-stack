#!/usr/bin/env bash
# last-stack-release-publish resolves fold's promote script from fold's
# Forgejo main (the bare mirror, after a fresh fetch), never from
# ~/.lastgit/mirrors, and refuses a script that names a lastdb:/// remote
# (papercut-release-publish-uses-stale-lastgit-fold-mirror-20260923).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-release-publish"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-release-promote.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.email test@example.invalid
git config --global user.name test
git config --global init.defaultBranch main
# No forge token lookups in a fixture.
export FORGE_TOKEN=fixture-token

# "Forgejo" fold: a plain bare repo with main.
upstream="$tmp/fold-upstream.git"
work="$tmp/fold-work"
git init --quiet --bare "$upstream"
git init --quiet "$work"
mkdir -p "$work/scripts/release"
cat >"$work/scripts/release/forge-promote-homebrew-stable.sh" <<'EOF'
#!/usr/bin/env bash
FORGE_ROOT_URL="${FORGE_ROOT_URL:-http://localhost:3300}"
echo "promote v1"
EOF
printf '%s\n' '# bump' >"$work/scripts/release/bump-homebrew-formula.rb"
git -C "$work" add -A
git -C "$work" commit --quiet -m v1
git -C "$work" push --quiet "$upstream" HEAD:refs/heads/main

# The portal's bare mirror, cloned before the upstream moves.
mirror="$tmp/fold.git"
git clone --quiet --bare "$upstream" "$mirror"
git -C "$mirror" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$mirror" fetch --quiet origin
export LAST_STACK_FOLD_GIT_MIRROR="$mirror"

# Upstream main moves on; the resolver must fetch it (not read the stale ref).
sed -i '' 's/promote v1/promote v2/' "$work/scripts/release/forge-promote-homebrew-stable.sh"
git -C "$work" commit --quiet -am v2
git -C "$work" push --quiet "$upstream" HEAD:refs/heads/main
v2="$(git -C "$work" rev-parse HEAD)"

# A frozen LastGit-era checkout that the resolver must never pick.
stale="$HOME/.lastgit/mirrors/fold/scripts/release"
mkdir -p "$stale"
printf '%s\n' 'LASTGIT_FORMULA_URL=lastdb:///homebrew-lastdb' >"$stale/forge-promote-homebrew-stable.sh"

out="$(python3 "$CLI" --resolve-promote-script)"
printf '%s\n' "$out" | grep -q "fold origin/main ${v2:0:12}"
script="$(printf '%s\n' "$out" | sed -n 's/^promote script: \([^ ]*\) .*/\1/p')"
grep -q 'promote v2' "$script"
test -f "$(dirname "$script")/bump-homebrew-formula.rb"
case "$script" in *"/.lastgit/"*) echo "resolved a LastGit mirror path" >&2; exit 1 ;; esac

# An explicit ~/.lastgit/mirrors path is refused.
if python3 "$CLI" --resolve-promote-script --fold-promote-script "$stale/forge-promote-homebrew-stable.sh" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo "expected a ~/.lastgit/mirrors script to be refused" >&2; exit 1
fi
grep -q 'frozen LastGit-era checkout' "$tmp/err"

# Any script that names a lastdb:/// remote is refused, wherever it lives.
bad="$tmp/elsewhere/forge-promote-homebrew-stable.sh"
mkdir -p "$(dirname "$bad")"
printf '%s\n' 'git clone lastdb:///homebrew-lastdb tap' >"$bad"
if LAST_STACK_CANARY_FORGE_PROMOTE="$bad" python3 "$CLI" --resolve-promote-script >"$tmp/out" 2>"$tmp/err"; then
  echo "expected a lastdb:/// script to be refused" >&2; exit 1
fi
grep -q 'names a lastdb:/// remote' "$tmp/err"

# fold main itself regresses to a lastdb:/// remote: refused after the fetch.
printf '%s\n' 'LASTGIT_FORMULA_URL=lastdb:///homebrew-lastdb' >>"$work/scripts/release/forge-promote-homebrew-stable.sh"
git -C "$work" commit --quiet -am v3
git -C "$work" push --quiet "$upstream" HEAD:refs/heads/main
if python3 "$CLI" --resolve-promote-script >"$tmp/out" 2>"$tmp/err"; then
  echo "expected fold main with a lastdb:/// remote to be refused" >&2; exit 1
fi
grep -q 'names a lastdb:/// remote' "$tmp/err"

# A failed fetch fails closed with a clear error (no stale fallback).
git -C "$mirror" config remote.origin.url "$tmp/missing.git"
if python3 "$CLI" --resolve-promote-script >"$tmp/out" 2>"$tmp/err"; then
  echo "expected a failed fetch to fail closed" >&2; exit 1
fi
grep -q 'fetch of fold main' "$tmp/err"

# No mirror at all: clear error.
if LAST_STACK_FOLD_GIT_MIRROR="$tmp/nope.git" python3 "$CLI" --resolve-promote-script >"$tmp/out" 2>"$tmp/err"; then
  echo "expected a missing mirror to fail" >&2; exit 1
fi
grep -q 'no fold bare mirror' "$tmp/err"

# The source never names the LastGit mirror as a candidate again.
if grep -n '".lastgit/mirrors' "$CLI" "$ROOT/bin/last-stack-canary-pipeline" "$ROOT/lib/fold_promote_script.py"; then
  echo "a LastGit mirror path is still a promote-script candidate" >&2; exit 1
fi

echo "PASS last-stack-release-publish-promote-script"
