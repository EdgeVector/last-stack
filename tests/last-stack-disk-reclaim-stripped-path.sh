#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT

host_git="$(command -v git)"
workspace="$tmp/workspace"
repo="$workspace/sample"
mkdir -p "$repo" "$tmp/home" "$tmp/empty-path"
"$host_git" -C "$repo" init -q
repo="$(cd "$repo" && pwd -P)"

HOME="$tmp/home"
PATH="$tmp/empty-path"
LAST_STACK_ROOT="$ROOT"
export HOME PATH LAST_STACK_ROOT

. "$ROOT/bin/last-stack-shell-prelude"
last_stack_require_tools git find bash date basename wc tr

for var in \
  LAST_STACK_TOOL_GIT \
  LAST_STACK_TOOL_FIND \
  LAST_STACK_TOOL_BASH \
  LAST_STACK_TOOL_DATE \
  LAST_STACK_TOOL_BASENAME \
  LAST_STACK_TOOL_WC \
  LAST_STACK_TOOL_TR
do
  eval "test -n \"\${$var:-}\""
done

repo_roots="$(
  last_stack_run_tool "$LAST_STACK_TOOL_BASH" -c '
    set -euo pipefail
    workspace="$1"
    find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
      | while IFS= read -r git_dir; do
          repo="${git_dir%/.git}"
          root="$(git -C "$repo" rev-parse --show-toplevel)"
          stamp="$(date -u +%Y%m%dT%H%M%SZ)"
          name="$(basename "$root")"
          byte_count="$(printf "%s\n" "$root" | wc -c | tr -d "[:space:]")"
          printf "%s\t%s\t%s\t%s\n" "$name" "$stamp" "$byte_count" "$root"
        done
  ' sh "$workspace"
)"

case "$repo_roots" in
  sample$'\t'[0-9]*T[0-9]*Z$'\t'[0-9]*$'\t'"$repo") ;;
  *)
    printf 'unexpected stripped-PATH repo discovery output: %s\n' "$repo_roots" >&2
    exit 1
    ;;
esac

echo "ok last-stack-disk-reclaim-stripped-path"
