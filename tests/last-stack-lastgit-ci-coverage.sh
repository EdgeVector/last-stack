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

# The helper has no fixed repo default any more; every fixture names its repo.
classify() {
  local file="$1"
  shift
  set +e
  "$helper" --repo last-stack --ps-file "$file" --json "$@" >"$tmp/out.json"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Raw form: no implicit --repo; the caller passes every flag.
classify_raw() {
  set +e
  "$helper" --json "$@" >"$tmp/out.json" 2>"$tmp/err.txt"
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

# 12) --head: a --ref watch that names the oid covers that head only
# (papercut-last-stack-lastgit-ci-coverage-rejects-head-20260903)
head_oid="e8a4988083dc7106ecf6b1a028e334972a2820ad"
cat >"$tmp/ref-head.txt" <<PS
88 lastgit ci watch --repo last-stack --context ci-required --ref $head_oid --keep-alive
PS
rc="$(classify "$tmp/ref-head.txt" --head "$head_oid")"
[ "$rc" = "4" ] || fail "ref-head full oid exit $rc"
assert_field covered true
assert_field supervised false
assert_field supervisor orphan-ref-watch
assert_field head "$head_oid"

# 12b) short --head prefix matches the same watch; case is folded
rc="$(classify "$tmp/ref-head.txt" --head E8A49880)"
[ "$rc" = "4" ] || fail "ref-head short oid exit $rc"
assert_field covered true
assert_field head e8a49880

# 12c) a different non-tip oid is NOT covered by that watch
rc="$(classify "$tmp/ref-head.txt" --head 0123456789abcdef0123456789abcdef01234567)"
[ "$rc" = "1" ] || fail "ref-head other oid exit $rc"
assert_field covered false
assert_field supervisor None

# 12d) a refs/heads/main watch cannot prove an oid: still uncovered under --head
rc="$(classify "$tmp/ref-only.txt" --head "$head_oid")"
[ "$rc" = "1" ] || fail "ref-only under --head exit $rc"
assert_field covered false

# 12e) forge run --all covers every head, --head included
rc="$(classify "$tmp/forge-all.txt" --head "$head_oid")"
[ "$rc" = "0" ] || fail "forge-all under --head exit $rc"
assert_field covered true
assert_field supervisor forge-run-all
assert_field head "$head_oid"

# 12f) malformed --head is a usage error, not a coverage verdict
rc="$(classify "$tmp/forge-all.txt" --head not-an-oid 2>/dev/null)"
[ "$rc" = "2" ] || fail "malformed --head exit $rc"
rc="$(classify "$tmp/forge-all.txt" --head abc12 2>/dev/null)"
[ "$rc" = "2" ] || fail "short --head exit $rc"

# 13) no --repo: never a silent last-stack default
# (papercut-last-stack-lastgit-ci-coverage-defaults-to-last-stack-repo)
mkdir -p "$tmp/not-a-repo"
rc="$( cd "$tmp/not-a-repo" && env -u LASTGIT_REPO bash -c \
  'set +e; "$1" --ps-file "$2" --json >"$3" 2>"$4"; echo $?' _ \
  "$helper" "$tmp/forge-all.txt" "$tmp/out.json" "$tmp/err.txt" )"
[ "$rc" = "2" ] || fail "no --repo outside git exit $rc (want 2)"
grep -q 'pass --repo' "$tmp/err.txt" || fail "no --repo: stderr does not say to pass --repo"
[ ! -s "$tmp/out.json" ] || fail "no --repo: helper printed a verdict on stdout"

# 13b) LASTGIT_REPO fills the repo and is reported as the source
rc="$( cd "$tmp/not-a-repo" && LASTGIT_REPO=laststore bash -c \
  'set +e; "$1" --ps-file "$2" --json >"$3" 2>"$4"; echo $?' _ \
  "$helper" "$tmp/forge-repos.txt" "$tmp/out.json" "$tmp/err.txt" )"
[ "$rc" = "1" ] || fail "LASTGIT_REPO=laststore vs --repos last-stack,fkanban exit $rc (want 1)"
assert_field repo laststore
assert_field repo_source env:LASTGIT_REPO
assert_field covered false

# 13c) the git origin remote of the cwd names the repo
git init -q "$tmp/laststore-wt"
git -C "$tmp/laststore-wt" remote add origin lastdb:///laststore
rc="$( cd "$tmp/laststore-wt" && env -u LASTGIT_REPO bash -c \
  'set +e; "$1" --ps-file "$2" --json >"$3" 2>"$4"; echo $?' _ \
  "$helper" "$tmp/forge-all.txt" "$tmp/out.json" "$tmp/err.txt" )"
[ "$rc" = "0" ] || fail "git-origin laststore exit $rc (want 0)"
assert_field repo laststore
assert_field repo_source git-origin
assert_field supervisor forge-run-all

# 13d) explicit --repo mismatch never reports the other repo as covered
rc="$(classify_raw --repo laststore --ps-file "$tmp/forge-repos.txt")"
[ "$rc" = "1" ] || fail "--repo laststore vs --repos last-stack,fkanban exit $rc"
assert_field repo laststore
assert_field repo_source flag
assert_field covered false

# 11) launchd plists must not ship a last-stack ci-required watch unit
if grep -n 'ci watch --repo last-stack' "$ROOT/launchd"/*.plist >/dev/null 2>&1; then
  fail "launchd/*.plist contains a last-stack ci watch unit; forge-primary already covers ci-required"
fi

echo "PASS last-stack-lastgit-ci-coverage"
