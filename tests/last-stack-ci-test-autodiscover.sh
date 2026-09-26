#!/usr/bin/env bash
# The auto-discovery block in .lastgit/ci.sh: an unlisted, non-exempt test runs
# in exactly one shard, a listed or exempt test is never run twice, and a red
# discovered test fails its shard. Fixture root only; no network, <1s.
# This file is itself listed nowhere: the required gate runs it through the
# block it tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CI="$ROOT/.lastgit/ci.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -qx 'ci_test_discovered' "$CI" || fail "ci.sh never calls ci_test_discovered"

work="$(mktemp -d "${TMPDIR:-/tmp}/ci-autodiscover.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.lastgit" "$work/tests"
sed -n '/^ci_test_discovered() {$/,/^}$/p' "$CI" > "$work/fn.sh"
[ -s "$work/fn.sh" ] || fail "could not extract ci_test_discovered from ci.sh"

printf '%s\n' 'ci_test tests/listed.sh' > "$work/.lastgit/ci.sh"
printf '%s\t%s\n' 'tests/exempt.sh' 'needs a live node; exercised by a routine instead' > "$work/tests/.ci-exempt"
for name in listed exempt new-a new-b new-c; do
  printf '#!/usr/bin/env bash\necho "%s" >> "%s/ran"\n' "$name" "$work" > "$work/tests/$name.sh"
done

run_shard() {
  ( cd "$work" && ROOT="$work" CI_SHARD_COUNT="$1" CI_SHARD_INDEX="$2" bash -c '. ./fn.sh; ci_test_discovered' ) >/dev/null
}

count=3
: > "$work/ran"
i=0
while [ "$i" -lt "$count" ]; do run_shard "$count" "$i"; i=$((i + 1)); done
sort "$work/ran" > "$work/ran.sorted"
printf '%s\n' new-a new-b new-c > "$work/want"
diff -u "$work/want" "$work/ran.sorted" || fail "discovered set across shards is not exactly the unlisted, non-exempt tests, once each"

# A red discovered test fails its shard.
printf '#!/usr/bin/env bash\nexit 7\n' > "$work/tests/new-red.sh"
red_failed=0
i=0
while [ "$i" -lt "$count" ]; do run_shard "$count" "$i" || red_failed=$((red_failed + 1)); i=$((i + 1)); done
[ "$red_failed" -eq 1 ] || fail "a red discovered test failed $red_failed shards, want exactly 1"

echo "ok last-stack-ci-test-autodiscover"
