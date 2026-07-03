#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fake_global="$tmp/global"
mkdir -p "$fake_global"
for tool in curl jq gh; do
  printf '#!/bin/sh\nexit 0\n' > "$fake_global/$tool"
  chmod +x "$fake_global/$tool"
done

PATH="$fake_global:/usr/bin:/bin" LAST_STACK_GLOBAL_PATH="$fake_global" \
  "$ROOT/bin/last-stack-cli-preflight" curl jq gh

if PATH="/usr/bin:/bin" LAST_STACK_GLOBAL_PATH="$fake_global" \
  "$ROOT/bin/last-stack-cli-preflight" curl jq gh missing-tool >/dev/null 2>"$tmp/missing.out"; then
  echo "expected missing CLI preflight to fail" >&2
  exit 1
fi

grep -q 'LAST_STACK_CLI_PATH_MISSING' "$tmp/missing.out"
grep -q 'missing-tool' "$tmp/missing.out"
grep -q 'export PATH=' "$tmp/missing.out"

echo "ok"
