#!/usr/bin/env bash
set -euo pipefail

# LAST_STACK_CI_FULL=1 is the path someone takes when they want EVERY test run.
# It used to run the loop under `set -e`, so the first red test aborted the run
# and every later test was silently skipped -- the exhaustive suite was strictly
# weaker at being exhaustive than the sharded gate. It also closed with an
# unconditional `exit 0`, unreachable only by accident, which would have turned
# the abort into a permanent false green the moment anyone made the loop
# tolerant. Both halves are asserted here against the real .lastgit/ci.sh in a
# fixture root, not by grepping its text.
# papercut-last-stack-ci-full-suite-aborts-on-first-failure-and-exits-zero-20260906

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CI="$ROOT/.lastgit/ci.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-full.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# The fixture copy of ci.sh must not inherit this run's shard variables. When
# this test is itself executed inside a shard, LAST_STACK_CI_SHARD_INDEX is set,
# the copy skips the whole `[ -z "$CI_SHARD_INDEX" ]` block that contains the
# CI_FULL branch, and it falls through to the real schedule -- which then looks
# for the real repo's test files inside the fixture root. Measured 2026-09-06:
# green standalone, red in shard 3 with `tests/last-stack-ci-full-suite.sh: No
# such file or directory`.
run_fixture() {
  env -u LAST_STACK_CI_SHARD_INDEX -u LAST_STACK_CI_SHARD_COUNT \
      -u LAST_STACK_CI_JOBS LAST_STACK_CI_FULL=1 bash "$1"
}

fixture_root() {
  # $1 = fixture directory, remaining args = test basenames to create.
  # A name ending in `-fails` exits 1; every other name exits 0.
  local dir="$1"; shift
  mkdir -p "$dir/.lastgit" "$dir/tests"
  cp "$CI" "$dir/.lastgit/ci.sh"
  local name
  for name in "$@"; do
    if [ "${name%-fails}" != "$name" ]; then
      printf '#!/usr/bin/env bash\necho RAN-%s\nexit 1\n' "$name" >"$dir/tests/$name.sh"
    else
      printf '#!/usr/bin/env bash\necho RAN-%s\n' "$name" >"$dir/tests/$name.sh"
    fi
  done
}

# --- a red test in the middle must not hide the tests after it ---------------
fixture_root "$WORK/red" a b-fails c
set +e
run_fixture "$WORK/red/.lastgit/ci.sh" >"$WORK/red.out" 2>"$WORK/red.err"
red_rc=$?
set -e

if [ "$red_rc" -eq 0 ]; then
  echo "CI_FULL reported success while tests/b-fails.sh failed" >&2
  exit 1
fi
for expected in RAN-a RAN-b-fails RAN-c; do
  grep -Fq "$expected" "$WORK/red.out" || {
    echo "CI_FULL stopped early: $expected never ran after an earlier failure" >&2
    cat "$WORK/red.out" "$WORK/red.err" >&2
    exit 1
  }
done
grep -Fq 'tests/b-fails.sh' "$WORK/red.err" || {
  echo "CI_FULL failed without naming the failing script" >&2
  cat "$WORK/red.err" >&2
  exit 1
}
grep -Fq 'tests/a.sh' "$WORK/red.err" && {
  echo "CI_FULL named a passing script in its failure summary" >&2
  exit 1
}

# --- every test failing must still be one non-zero exit, naming all of them --
fixture_root "$WORK/allred" d-fails e-fails
set +e
run_fixture "$WORK/allred/.lastgit/ci.sh" >"$WORK/allred.out" 2>"$WORK/allred.err"
allred_rc=$?
set -e
[ "$allred_rc" -ne 0 ] || { echo "CI_FULL reported success with every test red" >&2; exit 1; }
for expected in tests/d-fails.sh tests/e-fails.sh; do
  grep -Fq "$expected" "$WORK/allred.err" || {
    echo "CI_FULL failure summary omitted $expected" >&2
    cat "$WORK/allred.err" >&2
    exit 1
  }
done

# --- an all-green suite must still exit 0 ------------------------------------
fixture_root "$WORK/green" f g
set +e
run_fixture "$WORK/green/.lastgit/ci.sh" >"$WORK/green.out" 2>"$WORK/green.err"
green_rc=$?
set -e
[ "$green_rc" -eq 0 ] || {
  echo "CI_FULL failed on an all-green suite (rc=$green_rc)" >&2
  cat "$WORK/green.out" "$WORK/green.err" >&2
  exit 1
}
grep -Fq 'ran=2' "$WORK/green.out" || {
  echo "CI_FULL did not report how many tests it ran" >&2
  cat "$WORK/green.out" >&2
  exit 1
}

# The success line must be guarded by the failure check rather than closing the
# branch unconditionally. A tolerant loop with a trailing bare `exit 0` passes
# every assertion above only while the loop is intolerant, so pin the structure
# too: the branch's exit 0 must sit after the non-zero exit, not before it.
awk '/LAST_STACK_CI_FULL:-0/,/^  fi$/' "$CI" >"$WORK/branch.txt"
first_exit_1="$(grep -nE '^[[:space:]]*exit 1$' "$WORK/branch.txt" | head -1 | cut -d: -f1)"
first_exit_0="$(grep -nE '^[[:space:]]*exit 0$' "$WORK/branch.txt" | head -1 | cut -d: -f1)"
[ -n "$first_exit_1" ] || {
  echo "the CI_FULL branch has no failing exit path" >&2
  exit 1
}
if [ -n "$first_exit_0" ] && [ "$first_exit_1" -gt "$first_exit_0" ]; then
  echo "the CI_FULL branch exits 0 before it can exit 1" >&2
  exit 1
fi

echo "ok last-stack-ci-full-suite"
