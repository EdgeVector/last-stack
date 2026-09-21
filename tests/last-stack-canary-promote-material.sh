#!/usr/bin/env bash
# The promote-eligible action publishes on green (decision-2026-09-21):
#   - rows on next for the build → release-publish --if-needed runs, result in PROMOTE.md
#   - no next rows → skipped:no_next_rows, publisher never called
#   - publisher failure → exit 1 and the stderr tail lands in PROMOTE.md
#   - LAST_STACK_RELEASE_AUTO_PUBLISH=0 / --no-publish → material only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-promote-material"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/promote-material.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

build=0.23.3-200-gbbbbbbbbb
"$ROOT/bin/last-stack-registry-index" add-row --index "$tmp/next.json" --channel next --app brain \
  --source http://forge.local/brain.git --app-version 0.9.0 --sha "$(printf 'a%.0s' {1..40})" \
  --lastdb-version "$build" --proved-at 2026-09-21T00:00:00Z --proof-run run-1 >/dev/null

cat >"$tmp/publisher" <<'SH'
#!/usr/bin/env bash
echo "publisher $*" >>"${PUB_LOG:?}"
if [ "${PUB_FAIL:-0}" = 1 ]; then echo "clone of tap failed: 403" >&2; exit 1; fi
echo "RELEASE_PUBLISH build=$2 tag=v0.23.9 brew=published registry=PR EdgeVector/homebrew-lastdb#42"
SH
chmod +x "$tmp/publisher"

run() {
  env PUB_LOG="$tmp/pub.log" LAST_STACK_REGISTRY_NEXT_INDEX="$tmp/next.json" \
    LAST_STACK_CANARY_PROMOTE_ROOT="$tmp/promote" LAST_STACK_RELEASE_PUBLISH_BIN="$tmp/publisher" \
    "$@" "$BIN" --no-notify
}

# 1. green with rows → publishes
: >"$tmp/pub.log"
out="$(run env LAST_STACK_CANARY_CANDIDATE="$build")"
grep -q "publish=build=$build tag=v0.23.9 brew=published registry=PR" <<<"$out" || fail "publish result not reported: $out"
grep -q -- "--lastdb-version $build --if-needed" "$tmp/pub.log" || fail "publisher not called with --if-needed: $(cat "$tmp/pub.log")"
md="$(ls "$tmp"/promote/*/PROMOTE.md)"
grep -q "## Result" "$md" || fail "PROMOTE.md lacks the result section"
grep -q "brew=published" "$md" || fail "PROMOTE.md lacks the publish line"

# 2. no rows → skipped, publisher never called
: >"$tmp/pub.log"
out="$(run env LAST_STACK_CANARY_CANDIDATE=0.23.3-999-gzzzzzzzzz)"
grep -q "publish=skipped:no_next_rows" <<<"$out" || fail "no-rows case: $out"
[ ! -s "$tmp/pub.log" ] || fail "publisher was called without proved rows"

# 3. publisher failure → exit 1, stderr tail in PROMOTE.md
rm -rf "$tmp/promote"
set +e
out="$(run env LAST_STACK_CANARY_CANDIDATE="$build" PUB_FAIL=1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "publisher failure must exit 1, got $rc"
grep -q "publish=failed:rc=1" <<<"$out" || fail "failure not reported: $out"
grep -q "clone of tap failed: 403" "$(ls "$tmp"/promote/*/PROMOTE.md)" || fail "stderr tail missing from PROMOTE.md"

# 4. opt-out
: >"$tmp/pub.log"
out="$(run env LAST_STACK_CANARY_CANDIDATE="$build" LAST_STACK_RELEASE_AUTO_PUBLISH=0)"
grep -q "publish=material-only" <<<"$out" || fail "opt-out env: $out"
out="$(run env LAST_STACK_CANARY_CANDIDATE="$build" -- --no-publish 2>/dev/null || true)"
[ ! -s "$tmp/pub.log" ] || fail "opt-out still published"

echo "PASS last-stack-canary-promote-material"
