#!/usr/bin/env bash
# bin/last-stack-registry-proof-red-issue: ONE issue per RED build, deduped by
# title. Fake gh; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-proof-red-issue"
work="$(mktemp -d "${TMPDIR:-/tmp}/proof-red-issue.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

BUILD=0.23.3-2378-gbe41e547e
TITLE="registry-proof RED: $BUILD"
URL=https://github.com/EdgeVector/last-stack/actions/runs/1
calls="$work/calls"; : >"$calls"
cat >"$work/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$calls"
case "\$1 \$2" in
  "issue list") cat "$work/open.json" ;;
  "issue create") echo "https://github.com/EdgeVector/last-stack/issues/7" ;;
  *) : ;;
esac
GHEOF
chmod +x "$work/gh"
export GH_BIN="$work/gh"

jq -n '{verdict:"RED", fails:["brew-service:plist missing"]}' >"$work/red-shared.json"
printf 'verdict=RED\nshared_fail=1\npassed_apps=a b\nfailed_apps=\n' >"$work/attr-shared.txt"
jq -n '{verdict:"RED", fails:["install-apps:beta:pinned"]}' >"$work/red-app.json"
printf 'verdict=RED\nshared_fail=0\npassed_apps=alpha\nfailed_apps=beta\n' >"$work/attr-app.txt"
jq -n '{verdict:"GREEN", fails:[]}' >"$work/green.json"
printf 'verdict=GREEN\n' >"$work/attr-green.txt"

run() { "$BIN" --repo EdgeVector/last-stack --build "$BUILD" --proof "$1" --attribution "$2" --run-url "$URL"; }

# 1. RED, no open issue: one issue is created with the label and the title
echo '[]' >"$work/open.json"
out="$(run "$work/red-shared.json" "$work/attr-shared.txt")"
grep -q 'status=opened' <<<"$out" || fail "opened: $out"
[ "$(grep -c '^issue create' "$calls")" = 1 ] || fail "one create"
grep -q -- "--title $TITLE" "$calls" || fail "title"
grep -q -- '--label registry-proof-red' "$calls" || fail "label"

# 2. RED again, the issue is open: a comment, never a second issue
: >"$calls"
jq -n --arg t "$TITLE" '[{number: 7, title: $t}, {number: 9, title: "registry-proof RED: other"}]' >"$work/open.json"
out="$(run "$work/red-app.json" "$work/attr-app.txt")"
grep -q 'status=updated number=7' <<<"$out" || fail "updated: $out"
if grep -q '^issue create' "$calls"; then fail "must not open a second issue"; fi
grep -q '^issue comment 7 ' "$calls" || fail "comment on 7"
if grep -q '^issue close' "$calls"; then fail "RED must not close"; fi

# 3. GREEN closes the open issue for that build only
: >"$calls"
out="$(run "$work/green.json" "$work/attr-green.txt")"
grep -q 'status=closed number=7' <<<"$out" || fail "closed: $out"
grep -q '^issue close 7 ' "$calls" || fail "close 7"
if grep -q '^issue close 9' "$calls"; then fail "must not close another build's issue"; fi

# 4. GREEN with no open issue does nothing
: >"$calls"; echo '[]' >"$work/open.json"
out="$(run "$work/green.json" "$work/attr-green.txt")"
grep -q 'status=none' <<<"$out" || fail "none: $out"
if grep -qE '^issue (create|close|comment)' "$calls"; then fail "no write expected"; fi

# 5. a repository with Issues disabled: a warning and exit 0, never a failed run
cat >"$work/gh-off" <<GHEOF
#!/usr/bin/env bash
echo "the '\$3' repository has disabled issues" >&2
exit 1
GHEOF
chmod +x "$work/gh-off"
out="$(GH_BIN="$work/gh-off" run "$work/red-shared.json" "$work/attr-shared.txt")" || fail "disabled issues must not fail"
grep -q 'status=issues-disabled' <<<"$out" || fail "disabled issues: $out"
grep -q '::warning::' <<<"$out" || fail "disabled issues warning: $out"
# any other gh failure still fails
cat >"$work/gh-bad" <<GHEOF
#!/usr/bin/env bash
echo "HTTP 500" >&2
exit 1
GHEOF
chmod +x "$work/gh-bad"
if GH_BIN="$work/gh-bad" run "$work/red-shared.json" "$work/attr-shared.txt" >/dev/null 2>&1; then fail "a real gh error must fail"; fi

echo "ok last-stack-registry-proof-red-issue"
