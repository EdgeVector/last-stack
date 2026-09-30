#!/usr/bin/env bash
# `--sha-source github-ci` picks the newest main commit with a green ci-required
# check and, for an app with an artifact, a live ht-artifact-<sha>. Offline: a
# fake `gh` answers from a table. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-candidate-set"
work="$(mktemp -d "${TMPDIR:-/tmp}/candidate-set-ghci.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$work/home"
mkdir -p "$HOME"

# Fake gh. Commits of EdgeVector/pub (artifact app): c3 (green, no artifact),
# c2 (red), c1 (green + artifact). EdgeVector/plain (no artifact): p2 (red), p1 (green).
# EdgeVector/none: one commit, never green.
cat >"$work/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 2
path="$2"
case "$path" in
  repos/EdgeVector/pub/commits\?sha=main*) echo '["c3","c2","c1"]' ;;
  repos/EdgeVector/plain/commits\?sha=main*) echo '["p2","p1"]' ;;
  repos/EdgeVector/none/commits\?sha=main*) echo '["n1"]' ;;
  repos/EdgeVector/*/commits/c3/check-runs*|repos/EdgeVector/*/commits/c1/check-runs*|repos/EdgeVector/*/commits/p1/check-runs*)
    echo '["success"]' ;;
  repos/EdgeVector/*/commits/*/check-runs*) echo '["failure"]' ;;
  repos/EdgeVector/pub/actions/artifacts\?name=ht-artifact-c1*) echo 1 ;;
  repos/EdgeVector/pub/actions/artifacts*) echo 0 ;;
  *) exit 1 ;;
esac
GH
chmod +x "$work/gh"
printf '#!/bin/sh\necho "lastdbd 0.0.0-test"\n' >"$work/lastdbd"
chmod +x "$work/lastdbd"

cfg() { # name github artifact_app
  jq -n --arg g "https://github.com/EdgeVector/$1.git" --arg a "${2:-}" \
    '{github: $g, public: $g, install_name: "x", artifact_app: (if $a == "" then null else $a end)}'
}
jq -n --argjson pub "$(cfg pub pub)" --argjson plain "$(cfg plain)" --argjson none "$(cfg none)" \
  '{apps: {pub: $pub, plain: $plain, none: $none}}' >"$work/apps.json"

run_set() {
  local out="$1"
  shift
  LAST_STACK_GH_BIN="$work/gh" python3 "$BIN" --lastdbd "$work/lastdbd" --apps-config "$work/apps.json" \
    --sha-source github-ci --source-venue github --no-version-lookup --no-source-probe \
    --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

run_set "$work/ok.json" --only pub --only plain || { cat "$work/ok.json.stderr" >&2; fail "run failed"; }
[ "$(jq -r .apps.pub.sha "$work/ok.json")" = c1 ] || fail "pub must skip c3 (no artifact) and c2 (red): $(jq -r .apps.pub.sha "$work/ok.json")"
[ "$(jq -r .apps.plain.sha "$work/ok.json")" = p1 ] || fail "plain must skip the red p2"
[ "$(jq -r .apps.pub.sha_source "$work/ok.json")" = github-ci-main ] || fail "sha_source"

# A pin still wins.
run_set "$work/pin.json" --only pub --pin pub=c3 || fail "pin run"
[ "$(jq -r .apps.pub.sha "$work/pin.json")" = c3 ] || fail "pin must win"

# No green commit: exit 3, and the reason names the app.
if run_set "$work/none.json" --only none; then fail "an app with no green head must fail"; fi
grep -q 'none of the last' "$work/none.json.stderr" || fail "no reason: $(cat "$work/none.json.stderr")"
grep -q 'no commit could be resolved for: none' "$work/none.json.stderr" || fail "exit reason"

# A failing gh is not a green head.
printf '#!/bin/sh\nexit 1\n' >"$work/gh"
if run_set "$work/ghdown.json" --only plain; then fail "gh down must not yield a head"; fi

echo "ok last-stack-candidate-set-github-ci"
