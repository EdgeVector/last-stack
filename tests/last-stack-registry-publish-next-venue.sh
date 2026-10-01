#!/usr/bin/env bash
# last-stack-registry-publish-next writes `next` rows to the tap's gate of
# record. That is GitHub (2026-09-30); LastGit is retired and the Forgejo copy
# is frozen. A row merged on Forgejo never reaches a reader.
#
#   0. default venue is github (since 2026-09-30): the row branch is pushed to
#      the tap URL, `gh pr create` + `gh pr merge --squash --auto` run, and no
#      LastGit or Forgejo call is made.
#   1. venue=lastgit is refused (LastGit is retired): no CR path exists.
#   2. a tap checkout cloned from the frozen copy follows the venue URL.
# Hermetic: local bare repos stand in for the tap; fake lastdb/gh/forge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-publish-next"
work="$(mktemp -d "${TMPDIR:-/tmp}/publish-next-venue.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$work/home"
mkdir -p "$HOME"

# The tap: LastGit copy (live) and a frozen copy the old checkout came from.
src="$work/tap-src"
git init --quiet -b main "$src"
mkdir -p "$src/registry/proofs"
"$ROOT/bin/last-stack-registry-index" init --channel next --out "$src/registry/next.json" >/dev/null
git -C "$src" add registry
git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet -m scaffold
git clone --quiet --bare "$src" "$work/frozen.git"
git clone --quiet --bare "$src" "$work/tap-live.git"
git clone --quiet "$work/frozen.git" "$work/tapdir"

fake="$work/fake"
mkdir -p "$fake"
cat >"$fake/lastdb" <<'EOF'
#!/usr/bin/env bash
# Fake lastdb: `app index sign|verify` only.
[ "$1 $2" = "app index" ] || { echo "fake lastdb: $*" >&2; exit 2; }
case "$3" in
  sign)
    [ "${4:-}" = --help ] && exit 0
    idx=""; while [ "$#" -gt 0 ]; do [ "$1" = --index ] && idx="$2"; shift; done
    printf '{"alg":"ed25519"}\n' >"$idx.sig" ;;
  verify) exit 0 ;;
esac
EOF
cat >"$fake/forge-api" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/forge.calls"
exit 1
EOF
chmod +x "$fake/lastdb" "$fake/forge-api"
printf 'test-key\n' >"$work/signing.key"

cat >"$work/set.json" <<'EOF'
{"created_at":"2026-09-28T00:00:00Z","lastdb":{"build":"0.23.3-999-gtest"},
 "apps":{"routines":{"sha":"3bf55c676a1452e13cfa3f374116d230d3c909ec","app_version":"0.1.0",
   "source":"https://github.com/EdgeVector/routines.git","source_venue":"github",
   "public_source":"https://github.com/EdgeVector/routines.git","install_name":"routines","description":"x"}}}
EOF
printf '{"verdict":"GREEN","pass":30,"sandbox":"/tmp/x","lastdb_build":"0.23.3-999-gtest"}\n' >"$work/proof.json"

# --- default venue: github -------------------------------------------------
cat >"$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/gh.calls"
case "\$1 \$2" in
  "pr create") printf 'https://github.com/EdgeVector/homebrew-lastdb/pull/321\n' ;;
esac
EOF
chmod +x "$fake/gh"
git clone --quiet "$work/tap-live.git" "$work/tapdir-gh"
out="$(LAST_STACK_REGISTRY_TAP_URL="$work/tap-live.git" LAST_STACK_REGISTRY_TAP_DIR="$work/tapdir-gh" \
  LASTDB_REGISTRY_SIGNING_KEY="$work/signing.key" LASTDB_BIN="$fake/lastdb" GH_BIN="$fake/gh" \
  FORGE_API_BIN="$fake/forge-api" FORGE_GIT_BIN="$fake/forge-api" \
  "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" --proof-run run-gh 2>"$work/err")" \
  || { cat "$work/err" >&2; fail "github publish-next failed"; }
printf '%s\n' "$out" | grep -q '^REGISTRY_NEXT status=pr build=0.23.3-999-gtest apps=1 proof_run=run-gh pr=EdgeVector/homebrew-lastdb/321$' \
  || fail "github result line: $out"
[ ! -e "$work/forge.calls" ] || fail "the Forgejo path ran on the github venue"
grep -q '^pr create --repo EdgeVector/homebrew-lastdb --base main --head registry/next-0.23.3-999-gtest-' "$work/gh.calls" || fail "gh pr create: $(cat "$work/gh.calls")"
grep -q '^pr merge 321 --repo EdgeVector/homebrew-lastdb --squash --auto --delete-branch$' "$work/gh.calls" || fail "gh pr merge: $(cat "$work/gh.calls")"
git --git-dir "$work/tap-live.git" for-each-ref --format='%(refname:short)' 'refs/heads/registry/*' | grep -q 'run-gh\|0.23.3-999' || fail "row branch not pushed"

# --run-id puts the CI run id into the row branch name (closes
# papercut-last-stack-registry-publish-next-row-branch-same-second-collision-20260930):
# two applies in one second differ by run id as well as by pid.
: >"$work/gh.calls"
LAST_STACK_REGISTRY_TAP_URL="$work/tap-live.git" LAST_STACK_REGISTRY_TAP_DIR="$work/tapdir-gh" \
  LASTDB_REGISTRY_SIGNING_KEY="$work/signing.key" LASTDB_BIN="$fake/lastdb" GH_BIN="$fake/gh" \
  "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" --proof-run run-id-a --run-id 424242 >/dev/null 2>"$work/err" \
  || { cat "$work/err" >&2; fail "publish-next with --run-id failed"; }
grep -Eq '^pr create --repo EdgeVector/homebrew-lastdb --base main --head registry/next-0\.23\.3-999-gtest-[0-9TZ]+-424242-[0-9]+ ' "$work/gh.calls" \
  || fail "branch lacks the run id: $(cat "$work/gh.calls")"
if "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" --run-id 'a/b' >/dev/null 2>&1; then
  fail "a run id with a slash was accepted"
fi

# The retired LastGit venue is refused before any write.
if LAST_STACK_REGISTRY_TAP_VENUE=lastgit "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" >/dev/null 2>&1; then
  fail "the retired lastgit venue was accepted"
fi
# An unknown venue is refused before any write.
if LAST_STACK_REGISTRY_TAP_VENUE=gitlab "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" >/dev/null 2>&1; then
  fail "an unknown venue was accepted"
fi

echo "PASS last-stack-registry-publish-next-venue"
