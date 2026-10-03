#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CI="$ROOT/.lastgit/ci.sh"

grep -Fq 'LAST_STACK_CI_JOBS:-4' "$CI" || {
  echo "required CI must default to four bounded test shards" >&2
  exit 1
}
grep -Fq 'test_slot=$((ci_test_index % CI_SHARD_COUNT))' "$CI" || {
  echo "required CI must assign each test to exactly one shard" >&2
  exit 1
}
# The wait loop must collect every shard's failure AND keep its exit status.
# The status was discarded until 2026-10-03, so a signal and a red test printed
# the same word
# (papercut-ci-shard-exits-non-zero-with-no-failing-test-and-renders-as-a-plain-failed-20261003).
grep -Fq 'wait "$shard_pid" || shard_rc=$?' "$CI" || {
  echo "required CI must wait for every shard and keep its exit status" >&2
  exit 1
}
grep -Fq 'failed_shards="${failed_shards} ${shard_index}"' "$CI" || {
  echo "required CI must keep the index of every failing shard" >&2
  exit 1
}
grep -Fq 'shard_rcs="${shard_rcs} ${shard_index}:${shard_rc}"' "$CI" || {
  echo "required CI must keep each failing shard's exit status for the marker" >&2
  exit 1
}
grep -Fq 'if [ "$shard_failed" -ne 0 ]' "$CI" || {
  echo "required CI must fail when one shard fails" >&2
  exit 1
}
grep -Fq 'echo "ci_test start: $*"' "$CI" || {
  echo "required CI must print each scheduled test path before it runs" >&2
  exit 1
}
# Failing shard logs come last so the stored status tail names them, and the
# marker above each one is produced by ci_shard_failure_marker, which separates
# a red test from a shard that exited non-zero with nothing red in it. Its three
# branches are asserted behaviourally in tests/last-stack-ci-shard-supervisor.sh;
# here we only pin that the gate calls it instead of printing a bare word.
grep -Fq 'ci_shard_failure_marker "$failed_index" "$failed_rc"' "$CI" || {
  echo "required CI must classify each failing shard instead of printing a bare FAILED" >&2
  exit 1
}
grep -Fq 'cat "$CI_SHARD_LOG_DIR/$failed_index.log"' "$CI" || {
  echo "required CI must emit failing shard logs last so the status tail names them" >&2
  exit 1
}

# The registration guard must itself be scheduled. Without this line the guard
# that makes an unregistered test loud could quietly become unregistered, which
# is the exact failure it exists to prevent
# (papercut-last-stack-tests-can-land-unregistered-in-required-gate). This file
# is the right place for the assertion because it is registered near the head of
# the list and nothing would plausibly drop it.
grep -Fq 'ci_test tests/last-stack-ci-test-registration.sh' "$CI" || {
  echo "the test-registration guard is not scheduled in the required gate" >&2
  exit 1
}
if [ ! -f "$ROOT/tests/.ci-exempt" ]; then
  echo "tests/.ci-exempt is missing; the registration guard cannot record exclusions" >&2
  exit 1
fi

test_count="$(grep -c '^ci_test tests/' "$CI")"
if [ "$test_count" -lt 100 ]; then
  echo "required CI schedules only $test_count test scripts; expected the full required suite" >&2
  exit 1
fi
if grep -q '^bash tests/' "$CI"; then
  echo "a direct test invocation bypasses the bounded shard scheduler" >&2
  exit 1
fi

echo "ok last-stack-ci-sharding tests=$test_count"
