#!/usr/bin/env bash
# The GitHub gate of record: the required check is the final job `ci-required`,
# it needs every test job, and `publish` runs only after it via the reusable
# host-track artifact workflow. (This file guarded the Forge macOS host lane
# until last-stack moved to GitHub on 2026-09-30.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$ROOT/.github/workflows/ci-required.yml"
fail() { echo "FAIL last-stack-forge-ci-macos-route: $*" >&2; exit 1; }

[ -f "$workflow" ] || fail "no .github/workflows/ci-required.yml"
[ ! -e "$ROOT/.forgejo/workflows/ci.yml" ] || fail "a Forgejo workflow is back; GitHub is the gate"

shard="$(sed -n '/^  shard:/,/^  ci-required:/p' "$workflow")"
ci_required="$(sed -n '/^  ci-required:/,/^  publish:/p' "$workflow")"
publish="$(sed -n '/^  publish:/,$p' "$workflow")"
[ -n "$shard" ] || fail "no shard job"
[ -n "$ci_required" ] || fail "no ci-required job"
[ -n "$publish" ] || fail "no publish job"

printf '%s\n' "$shard" | grep -qx '    runs-on: macos-latest' || fail "shards left the macOS runner"
printf '%s\n' "$shard" | grep -q 'LAST_STACK_CI_SHARD_INDEX: \${{ matrix.index }}' || fail "shards lost their index"
printf '%s\n' "$ci_required" | grep -q '    name: ci-required' || fail "the required check name changed"
printf '%s\n' "$ci_required" | grep -qF 'needs: [lint, shard]' || fail "ci-required does not need lint and shard"
printf '%s\n' "$ci_required" | grep -qF 'if: ${{ always() }}' || fail "ci-required must run with always()"
printf '%s\n' "$publish" | grep -qF 'needs: [ci-required]' || fail "publish no longer waits for ci-required"
printf '%s\n' "$publish" | grep -qF "github.ref == 'refs/heads/main'" || fail "publish is not limited to main"
printf '%s\n' "$publish" | grep -qF 'uses: ./.github/workflows/host-track-artifact.yml' || fail "publish lost the reusable workflow"

# Every ci.sh shard index the matrix runs must exist and the count must match.
count="$(sed -n 's/^  LAST_STACK_CI_SHARD_COUNT: "\([0-9]*\)"$/\1/p' "$workflow")"
[ -n "$count" ] || fail "no LAST_STACK_CI_SHARD_COUNT"
matrix="$(sed -n 's/^        index: \[\(.*\)\]$/\1/p' "$workflow" | tr -d ' ' | tr ',' '\n' | wc -l | tr -d ' ')"
[ "$matrix" = "$count" ] || fail "matrix has $matrix shards, count is $count"

echo "ok last-stack-forge-ci-macos-route"
