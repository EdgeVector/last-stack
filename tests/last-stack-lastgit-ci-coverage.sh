#!/usr/bin/env bash
# Fixture classifier for last-stack LastGit ci-required coverage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper="$ROOT/bin/last-stack-lastgit-ci-coverage"
tmp="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-ci-coverage-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

test -x "$helper"
bash -n "$helper"

classify() {
  local file="$1"
  shift
  set +e
  "$helper" --ps-file "$file" --json "$@" >"$tmp/out.json"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

assert_field() {
  local key="$1" want="$2"
  python3 - "$tmp/out.json" "$key" "$want" <<'PY'
import json, sys
path, key, want = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
got = data.get(key)
if want in ("true", "false"):
    want_v = want == "true"
    if got is not want_v:
        raise SystemExit(f"{key}: got {got!r} want {want_v!r} payload={data}")
else:
    if str(got) != want:
        raise SystemExit(f"{key}: got {got!r} want {want!r} payload={data}")
PY
}

# 1) fleet supervisor covers last-stack
cat >"$tmp/forge-all.txt" <<'PS'
19711 bash /Users/ci-runner/.lastgit/host-checkout/lastgit/.lastgit/forge-run.sh
19766 lastgit forge run --all --context ci-required --exit-on-stale-binary
32094 /Users/ci-runner/.local/bin/lastgit ci watch --repo lastseek --context artifact-release --ref refs/heads/main --keep-alive
PS
rc="$(classify "$tmp/forge-all.txt")"
[ "$rc" = "0" ] || fail "forge-all exit $rc"
assert_field covered true
assert_field supervised true
assert_field supervisor forge-run-all
assert_field duplicate_repo_watch false

# 2) launchd supervisor fallback covers sandboxed callers without ps access
: >"$tmp/empty-ps.txt"
cat >"$tmp/launchctl-running.txt" <<'LAUNCHCTL'
gui/501/com.edgevector.lastgit-forge-primary = {
  state = running
  program = /Users/ci-runner/.lastgit/host-checkout/lastgit/.lastgit/forge-run.sh
}
LAUNCHCTL
rc="$(classify "$tmp/empty-ps.txt" --launchctl-file "$tmp/launchctl-running.txt")"
[ "$rc" = "0" ] || fail "launchd fallback exit $rc"
assert_field covered true
assert_field supervised true
assert_field supervisor launchd-forge-primary
assert_field duplicate_repo_watch false

# 3) default context is ci-required
cat >"$tmp/forge-default.txt" <<'PS'
11 lastgit forge run --all --exit-on-stale-binary
PS
rc="$(classify "$tmp/forge-default.txt")"
[ "$rc" = "0" ] || fail "forge-default exit $rc"
assert_field covered true
assert_field supervisor forge-run-all

# 4) --repos list including last-stack
cat >"$tmp/forge-repos.txt" <<'PS'
12 lastgit forge run --repos last-stack,fkanban --context ci-required
PS
rc="$(classify "$tmp/forge-repos.txt")"
[ "$rc" = "0" ] || fail "forge-repos exit $rc"
assert_field supervisor forge-run-repos

# 5) excluded last-stack is uncovered
cat >"$tmp/forge-exclude.txt" <<'PS'
13 lastgit forge run --all --exclude last-stack --context ci-required
PS
rc="$(classify "$tmp/forge-exclude.txt")"
[ "$rc" = "1" ] || fail "forge-exclude exit $rc"
assert_field covered false

# 6) duplicate per-repo watch
cat >"$tmp/dup.txt" <<'PS'
19766 lastgit forge run --all --context ci-required
6911 lastgit ci watch --repo last-stack --context ci-required --max-concurrency 1
PS
rc="$(classify "$tmp/dup.txt")"
[ "$rc" = "3" ] || fail "duplicate exit $rc"
assert_field duplicate_repo_watch true
assert_field covered true

# 7) orphan per-repo watch without forge
cat >"$tmp/orphan.txt" <<'PS'
6911 lastgit ci watch --repo last-stack --context ci-required
PS
rc="$(classify "$tmp/orphan.txt")"
[ "$rc" = "4" ] || fail "orphan exit $rc"
assert_field supervised false
assert_field supervisor orphan-ci-watch

# 8) --ref watch is overlapping, not coverage
cat >"$tmp/ref-only.txt" <<'PS'
88 lastgit ci watch --repo last-stack --context ci-required --ref refs/heads/main --keep-alive
PS
rc="$(classify "$tmp/ref-only.txt")"
[ "$rc" = "1" ] || fail "ref-only exit $rc"
assert_field covered false

# 9) agent prompt prose must not count as a watcher
cat >"$tmp/prose.txt" <<'PS'
95856 grok -m grok-4.5 -p lastgit ci watch --repo last-stack --context ci-required
PS
rc="$(classify "$tmp/prose.txt")"
[ "$rc" = "1" ] || fail "prose exit $rc"
assert_field covered false

# 10) deploy watchers are a different context
cat >"$tmp/deploy.txt" <<'PS'
19940 lastgit ci watch --repo ops-terminal --context deploy-prod --ref refs/heads/main
PS
rc="$(classify "$tmp/deploy.txt")"
[ "$rc" = "1" ] || fail "deploy exit $rc"
assert_field covered false

# 11) launchd plists must not ship a last-stack ci-required watch unit
if grep -n 'ci watch --repo last-stack' "$ROOT/launchd"/*.plist >/dev/null 2>&1; then
  fail "launchd/*.plist contains a last-stack ci watch unit; forge-primary already covers ci-required"
fi

echo "PASS last-stack-lastgit-ci-coverage"
