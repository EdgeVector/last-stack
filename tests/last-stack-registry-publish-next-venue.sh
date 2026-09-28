#!/usr/bin/env bash
# last-stack-registry-publish-next writes `next` rows to the tap's gate of
# record. Since LastGit era 3 (2026-09-27) that is LastGit; the tap's GitHub
# mirror (what `lastdb app resolve` reads) follows LastGit, and the Forgejo
# copy is frozen. A row merged on Forgejo never reaches a reader.
#
#   1. default venue: the row branch is pushed to the tap URL, a LastGit CR is
#      opened with auto-merge gated on ci-required, and no Forgejo call is made.
#   2. a tap checkout cloned from the frozen copy follows the venue URL.
#   3. the rows carry the candidate set's `source` (the LastGit URL).
# Hermetic: local bare repos stand in for the tap; fake lastdb/lastgit/forge.
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
git clone --quiet --bare "$src" "$work/lastgit.git"
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
cat >"$fake/lastgit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/lastgit.calls"
printf '{"cr_id":"cr-test-1","state":"open"}\n'
EOF
cat >"$fake/forge-api" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/forge.calls"
exit 1
EOF
chmod +x "$fake/lastdb" "$fake/lastgit" "$fake/forge-api"
printf 'test-key\n' >"$work/signing.key"

cat >"$work/set.json" <<'EOF'
{"created_at":"2026-09-28T00:00:00Z","lastdb":{"build":"0.23.3-999-gtest"},
 "apps":{"routines":{"sha":"3bf55c676a1452e13cfa3f374116d230d3c909ec","app_version":"0.1.0",
   "source":"lastdb:///routines","source_venue":"lastgit",
   "public_source":"https://github.com/EdgeVector/routines.git","install_name":"routines","description":"x"}}}
EOF
printf '{"verdict":"GREEN","pass":30,"sandbox":"/tmp/x","lastdb_build":"0.23.3-999-gtest"}\n' >"$work/proof.json"

out="$(LAST_STACK_REGISTRY_TAP_URL="$work/lastgit.git" LAST_STACK_REGISTRY_TAP_DIR="$work/tapdir" \
  LASTDB_REGISTRY_SIGNING_KEY="$work/signing.key" LASTDB_BIN="$fake/lastdb" LASTGIT_BIN="$fake/lastgit" \
  FORGE_API_BIN="$fake/forge-api" FORGE_GIT_BIN="$fake/forge-api" \
  "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" --proof-run run-venue 2>"$work/err")" \
  || { cat "$work/err" >&2; fail "publish-next failed"; }

printf '%s\n' "$out" | grep -q '^REGISTRY_NEXT status=cr build=0.23.3-999-gtest apps=1 proof_run=run-venue pr=lastgit://homebrew-lastdb/cr/cr-test-1$' \
  || fail "result line: $out"
[ ! -e "$work/forge.calls" ] || fail "the Forgejo path ran: $(cat "$work/forge.calls")"
calls="$(cat "$work/lastgit.calls")"
case "$calls" in
  "cr create homebrew-lastdb --head registry/next-0.23.3-999-gtest-"*"--base main"*"--auto-merge --require-status ci-required --json") ;;
  *) fail "lastgit call: $calls" ;;
esac
[ "$(git -C "$work/tapdir" remote get-url origin)" = "$work/lastgit.git" ] || fail "tap checkout still points at the frozen copy"
branch="$(git --git-dir "$work/lastgit.git" for-each-ref --format='%(refname:short)' 'refs/heads/registry/*')"
[ -n "$branch" ] || fail "no row branch was pushed to the LastGit tap"
git --git-dir "$work/frozen.git" for-each-ref 'refs/heads/registry/*' | grep -q . && fail "row branch went to the frozen copy"
git --git-dir "$work/lastgit.git" show "$branch:registry/next.json" \
  | jq -e '.apps[] | select(.app_id == "routines") | .source == "lastdb:///routines" and (.compat[0].sha | startswith("3bf55c676a14"))' >/dev/null \
  || fail "next row does not carry the candidate set's LastGit source"
git --git-dir "$work/lastgit.git" cat-file -e "$branch:registry/proofs/run-venue.json" || fail "proof record missing"

# An unknown venue is refused before any write.
if LAST_STACK_REGISTRY_TAP_VENUE=gitlab "$BIN" --candidate-set "$work/set.json" --proof "$work/proof.json" >/dev/null 2>&1; then
  fail "an unknown venue was accepted"
fi

echo "PASS last-stack-registry-publish-next-venue"
