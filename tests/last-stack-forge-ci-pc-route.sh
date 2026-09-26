#!/usr/bin/env bash
# decision-2026-09-22-last-stack-ci-required-pc-linux: the required gate runs on
# the gaming PC; publish stays on the Mac host, where the artifact CAS lives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$ROOT/.forgejo/workflows/ci.yml"
fail() { echo "FAIL last-stack-forge-ci-pc-route: $*" >&2; exit 1; }

ci_required="$(sed -n '/^  ci-required:/,/^  publish:/p' "$workflow")"
publish="$(sed -n '/^  publish:/,$p' "$workflow")"
[ -n "$ci_required" ] || fail "no ci-required job"
[ -n "$publish" ] || fail "no publish job"

printf '%s\n' "$ci_required" | grep -qx '    runs-on: pc-linux' || fail "ci-required does not run on pc-linux"
printf '%s\n' "$ci_required" | grep -q '    name: ci-required' || fail "the required context name changed"
if printf '%s\n' "$ci_required" | grep -q 'host.docker.internal/localhost'; then
  fail "ci-required rewrites the forge URL to localhost; a PC container cannot reach that"
fi
if printf '%s\n' "$ci_required" | grep -Eq '^[[:space:]]*LAST_STACK_CI_HOST_LOCK:'; then
  fail "ci-required takes the Mac host lock"
fi
if printf '%s\n' "$ci_required" | grep -q '/opt/homebrew/bin'; then
  fail "ci-required adds Mac host toolchains to PATH"
fi
printf '%s\n' "$ci_required" | grep -q 'LAST_STACK_CI_PR_HEAD_SHA:' || fail "ci-required lost the superseded-head skip"
printf '%s\n' "$publish" | grep -qx '    runs-on: macos-arm64' || fail "publish left the Mac host lane"
printf '%s\n' "$publish" | grep -qx '    needs: ci-required' || fail "publish no longer waits for ci-required"

echo "ok last-stack-forge-ci-pc-route"
