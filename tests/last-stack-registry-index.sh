#!/usr/bin/env bash
# Fixture test for bin/last-stack-registry-index: rows land, re-proof replaces,
# promote copies one node build to another channel with the public source,
# unreachable commits refuse the promote, and a stale .sig is dropped on write.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-index"
work="$(mktemp -d "${TMPDIR:-/tmp}/registry-index-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A local "public" repo so --verify-reachable has something real to fetch from.
git init --quiet -b main "$work/pub-src"
git -C "$work/pub-src" -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m one
reachable="$(git -C "$work/pub-src" rev-parse HEAD)"
git clone --quiet --bare "$work/pub-src" "$work/pub.git"
unreachable="0123456789abcdef0123456789abcdef01234567"

next="$work/next.json"
"$BIN" add-row --index "$next" --channel next --app brain --source http://forge.local/brain.git \
  --description "knowledge" --app-version 0.9.0 --sha "$reachable" --lastdb-version 0.23.3-100-gaaaaaaaaa \
  --proved-at 2026-09-19T00:00:00Z --proof-run run-1 >/dev/null
"$BIN" add-row --index "$next" --app brain --app-version 0.9.1 --sha "$reachable" \
  --lastdb-version 0.23.3-200-gbbbbbbbbb --proved-at 2026-09-20T00:00:00Z --proof-run run-2 >/dev/null
# Re-proof of the same (sha, build) replaces the row instead of duplicating it.
"$BIN" add-row --index "$next" --app brain --app-version 0.9.1 --sha "$reachable" \
  --lastdb-version 0.23.3-200-gbbbbbbbbb --proved-at 2026-09-20T01:00:00Z --proof-run run-2b >/dev/null
"$BIN" add-row --index "$next" --app kanban --source http://forge.local/fkanban.git --app-version 2.0.0 \
  --sha "$unreachable" --lastdb-version 0.23.3-200-gbbbbbbbbb --proved-at 2026-09-20T00:00:00Z --proof-run run-2 >/dev/null

[ "$(jq -r '.channel' "$next")" = next ] || fail "channel"
[ "$(jq -r '.apps | length' "$next")" = 2 ] || fail "two apps expected"
[ "$(jq -r '.apps[] | select(.app_id=="brain") | .compat | length' "$next")" = 2 ] || fail "re-proof duplicated a row"
[ "$(jq -r '.apps[] | select(.app_id=="brain") | .compat[-1].proof_run' "$next")" = run-2b ] || fail "re-proof did not replace"
[ "$(jq -r '.apps[0].app_id' "$next")" = brain ] || fail "apps not sorted"

# A new app without --source is refused.
if "$BIN" add-row --index "$next" --app search --app-version 1 --sha "$reachable" --lastdb-version x --proof-run r >/dev/null 2>&1; then
  fail "new app without --source was accepted"
fi

# builds lists both node builds, newest proof first.
first_build="$("$BIN" builds --index "$next" | head -n1 | cut -f1)"
[ "$first_build" = 0.23.3-200-gbbbbbbbbb ] || fail "builds order: $first_build"

# Promote build 200 to stable with the public source map. kanban's commit is
# unreachable on its public source, so the promote must refuse and write nothing.
printf '{"brain":"%s","kanban":"%s"}\n' "$work/pub.git" "$work/pub.git" >"$work/sources.json"
stable="$work/stable.json"
"$BIN" init --channel stable --out "$stable" >/dev/null
if "$BIN" promote --source-index "$next" --target-index "$stable" --lastdb-version 0.23.3-200-gbbbbbbbbb \
  --source-map "$work/sources.json" --verify-reachable >/dev/null 2>"$work/promote.err"; then
  fail "promote with an unreachable commit succeeded"
fi
grep -q "UNREACHABLE kanban" "$work/promote.err" || fail "unreachable app not named: $(cat "$work/promote.err")"
[ "$(jq -r '.apps | length' "$stable")" = 0 ] || fail "refused promote wrote rows"

# Fix kanban's row to a reachable commit and promote again.
"$BIN" add-row --index "$next" --app kanban --app-version 2.0.1 --sha "$reachable" \
  --lastdb-version 0.23.3-200-gbbbbbbbbb --proved-at 2026-09-20T02:00:00Z --proof-run run-3 >/dev/null
"$BIN" promote --source-index "$next" --target-index "$stable" --lastdb-version 0.23.3-200-gbbbbbbbbb \
  --source-map "$work/sources.json" --verify-reachable >/dev/null
[ "$(jq -r '.apps | length' "$stable")" = 2 ] || fail "promote did not copy both apps"
[ "$(jq -r '.apps[] | select(.app_id=="brain") | .source' "$stable")" = "$work/pub.git" ] || fail "source not rewritten"
[ "$(jq -r '.apps[] | select(.app_id=="brain") | .compat | length' "$stable")" = 1 ] || fail "promote copied more than the newest row for the build"
[ "$(jq -r '.apps[] | select(.app_id=="brain") | .compat[0].app_version' "$stable")" = 0.9.1 ] || fail "wrong brain row promoted"
[ "$(jq -r '.apps[] | select(.app_id=="kanban") | .compat[0].app_version' "$stable")" = 2.0.1 ] || fail "wrong kanban row promoted"

# A build with no rows is a clear non-zero.
if "$BIN" promote --source-index "$next" --target-index "$stable" --lastdb-version 0.99.0-1-gnothing >/dev/null 2>&1; then
  fail "promote of an unknown build succeeded"
fi

# A stale signature is dropped when the index is rewritten.
echo '{"stale":true}' >"$stable.sig"
"$BIN" add-row --index "$stable" --app brain --app-version 0.9.2 --sha "$reachable" \
  --lastdb-version 0.23.3-300-gccccccccc --proved-at 2026-09-21T00:00:00Z --proof-run run-4 >/dev/null
[ ! -e "$stable.sig" ] || fail "stale .sig survived a rewrite"

# show filters by build.
"$BIN" show --index "$stable" --lastdb-version 0.23.3-300-gccccccccc | grep -q "run-4" || fail "show lacks the filtered row"

echo "PASS last-stack-registry-index"
