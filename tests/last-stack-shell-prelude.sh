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
printf '#!/bin/sh\nexit 0\n' > "$fake_global/gh"
chmod +x "$fake_global/gh"

PATH="/usr/bin:/bin"
LAST_STACK_GLOBAL_PATH="$fake_global"
export PATH LAST_STACK_GLOBAL_PATH

. "$ROOT/bin/last-stack-shell-prelude"

command -v gh >/dev/null 2>&1
PATH="/usr/bin:/bin"
unset LAST_STACK_GLOBAL_PATH
LAST_STACK_ROOT="$ROOT"
export PATH LAST_STACK_ROOT
. "$ROOT/bin/last-stack-shell-prelude"
command -v last-stack-json-get >/dev/null 2>&1
case ":$PATH:" in
  *":$ROOT/bin:"*) ;;
  *) echo "expected prelude to prepend last-stack bin path" >&2; exit 1 ;;
esac

echo "ok"
