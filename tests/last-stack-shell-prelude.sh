#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT
HOME="$tmp/home"
mkdir -p "$HOME"
export HOME

fake_global="$tmp/global"
mkdir -p "$fake_global"
printf '#!/bin/sh\nexit 0\n' > "$fake_global/gh"
chmod +x "$fake_global/gh"
printf '#!/usr/bin/env bash\nprintf shim-ok\n' > "$fake_global/shim-with-env-bash"
chmod +x "$fake_global/shim-with-env-bash"

PATH="/usr/bin:/bin"
LAST_STACK_GLOBAL_PATH="$fake_global"
OBS_SENTRY_DSN=lastsecrets://obs-sentry-dsn-routines
export PATH LAST_STACK_GLOBAL_PATH OBS_SENTRY_DSN
RUSTC_WRAPPER=sccache
export RUSTC_WRAPPER

. "$ROOT/bin/last-stack-shell-prelude"

command -v gh >/dev/null 2>&1
test "${OBS_SENTRY_DSN+x}" != x
test "${RUSTC_WRAPPER+x}" = x
test -z "$RUSTC_WRAPPER"
test "$LAST_STACK_SCCACHE_BYPASS" = 1
last_stack_require_tools gh
test "$LAST_STACK_TOOL_GH" = "$fake_global/gh"
last_stack_require_tools shim-with-env-bash
PATH="$fake_global"
test "$(last_stack_run_tool "$LAST_STACK_TOOL_SHIM_WITH_ENV_BASH")" = "shim-ok"

OBS_SENTRY_DSN=https://public@example.invalid/1
export OBS_SENTRY_DSN
. "$ROOT/bin/last-stack-shell-prelude"
test "$OBS_SENTRY_DSN" = https://public@example.invalid/1
unset OBS_SENTRY_DSN

LAST_STACK_RUSTC_WRAPPER=known-good-wrapper
export LAST_STACK_RUSTC_WRAPPER
. "$ROOT/bin/last-stack-shell-prelude"
test "$RUSTC_WRAPPER" = known-good-wrapper
test "$LAST_STACK_SCCACHE_BYPASS" = 0
unset LAST_STACK_RUSTC_WRAPPER

LAST_STACK_PRESERVE_RUSTC_WRAPPER=1
RUSTC_WRAPPER=preserved-wrapper
export LAST_STACK_PRESERVE_RUSTC_WRAPPER RUSTC_WRAPPER
. "$ROOT/bin/last-stack-shell-prelude"
test "$RUSTC_WRAPPER" = preserved-wrapper
test "$LAST_STACK_SCCACHE_BYPASS" = 0
unset LAST_STACK_PRESERVE_RUSTC_WRAPPER RUSTC_WRAPPER

PATH="/usr/bin:/bin"
unset LAST_STACK_GLOBAL_PATH
LAST_STACK_ROOT="$ROOT"
export PATH LAST_STACK_ROOT
. "$ROOT/bin/last-stack-shell-prelude"
command -v last-stack-json-get >/dev/null 2>&1
last_stack_require_tools git awk basename rm bash last-stack-json-get
test -n "$LAST_STACK_TOOL_GIT"
test -n "$LAST_STACK_TOOL_AWK"
test -n "$LAST_STACK_TOOL_BASENAME"
test -n "$LAST_STACK_TOOL_RM"
test -n "$LAST_STACK_TOOL_BASH"
test "$LAST_STACK_TOOL_LAST_STACK_JSON_GET" = "$ROOT/bin/last-stack-json-get"
test -n "$LAST_STACK_PRELUDE_PATH"
case ":$PATH:" in
  *":$ROOT/bin:"*) ;;
  *) echo "expected prelude to prepend last-stack bin path" >&2; exit 1 ;;
esac

empty_global="$tmp/empty-global"
mkdir -p "$empty_global"
PATH="$empty_global"
LAST_STACK_GLOBAL_PATH="$empty_global"
export PATH LAST_STACK_GLOBAL_PATH
. "$ROOT/bin/last-stack-shell-prelude"
if last_stack_require_tools missing-basic-tool >/dev/null 2>"$tmp/missing.err"; then
  echo "expected missing stripped-PATH tool to fail" >&2
  exit 1
fi
PATH="/usr/bin:/bin"
export PATH
grep -q 'LAST_STACK_CLI_PATH_MISSING' "$tmp/missing.err"
grep -q 'Required CLI(s) not visible:' "$tmp/missing.err"
if grep -q 'command not found' "$tmp/missing.err"; then
  echo "expected controlled missing-tool error, not shell command-not-found" >&2
  exit 1
fi

workspace="$tmp/workspace"
fake_home="$tmp/home"
mkdir -p "$fake_home"
mkdir -p "$workspace/brain/bin"
mkdir -p "$workspace/fkanban/bin"
mkdir -p "$fake_home/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$workspace/brain/bin/brain"
printf '#!/bin/sh\nexit 0\n' > "$workspace/fkanban/bin/fkanban"
printf '#!/bin/sh\nexit 0\n' > "$fake_home/.local/bin/brain"
printf '#!/bin/sh\nexit 0\n' > "$fake_home/.local/bin/fkanban"
chmod +x "$workspace/brain/bin/brain"
chmod +x "$workspace/fkanban/bin/fkanban"
chmod +x "$fake_home/.local/bin/brain"
chmod +x "$fake_home/.local/bin/fkanban"
PATH="/usr/bin:/bin"
LAST_STACK_WORKSPACE="$workspace"
LAST_STACK_EDGEVECTOR_ROOT="$tmp/no-edgevector"
unset LAST_STACK_GLOBAL_PATH
export PATH LAST_STACK_WORKSPACE LAST_STACK_EDGEVECTOR_ROOT HOME
. "$ROOT/bin/last-stack-shell-prelude"
last_stack_require_tools brain
test "$LAST_STACK_TOOL_BRAIN" = "$fake_home/.local/bin/brain"
last_stack_require_tools fkanban
test "$LAST_STACK_TOOL_FKANBAN" = "$fake_home/.local/bin/fkanban"

echo "ok"
