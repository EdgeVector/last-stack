#!/usr/bin/env bash
# ci-required and the stable artifact publisher run on the macOS host lane.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$ROOT/.forgejo/workflows/ci.yml"
fail() { echo "FAIL last-stack-forge-ci-macos-route: $*" >&2; exit 1; }

ci_required="$(sed -n '/^  ci-required:/,/^  publish:/p' "$workflow")"
publish="$(sed -n '/^  publish:/,$p' "$workflow")"
[ -n "$ci_required" ] || fail "no ci-required job"
[ -n "$publish" ] || fail "no publish job"

printf '%s\n' "$ci_required" | grep -qx '    runs-on: macos-arm64' || fail "ci-required does not run on macos-arm64"
printf '%s\n' "$ci_required" | grep -q '    name: ci-required' || fail "the required context name changed"
printf '%s\n' "$ci_required" | grep -q 'host.docker.internal/localhost' \
  || fail "ci-required does not rewrite the host runner forge URL"
printf '%s\n' "$ci_required" | grep -Eq '^[[:space:]]*LAST_STACK_CI_HOST_LOCK: "1"' \
  || fail "ci-required does not take the Mac host lock"
printf '%s\n' "$ci_required" | grep -q '/opt/homebrew/bin' \
  || fail "ci-required does not add Mac host toolchains to PATH"
printf '%s\n' "$ci_required" | grep -q 'LAST_STACK_CI_PR_HEAD_SHA:' || fail "ci-required lost the superseded-head skip"
printf '%s\n' "$publish" | grep -qx '    runs-on: macos-arm64' || fail "publish left the Mac host lane"
printf '%s\n' "$publish" | grep -qx '    needs: ci-required' || fail "publish no longer waits for ci-required"

echo "ok last-stack-forge-ci-macos-route"
