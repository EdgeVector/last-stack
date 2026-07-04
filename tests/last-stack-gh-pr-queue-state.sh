#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$@" > "$GH_ARGS"
case " $* " in
  *" -R "*)
    echo "helper must not pass -R to gh api graphql" >&2
    exit 1
    ;;
esac
test "$1" = api
test "$2" = graphql
printf '{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"autoMergeRequest":null}}}}\n'
GH
chmod +x "$fake_bin/gh"

GH_ARGS="$tmp/args"
export GH_ARGS
PATH="$fake_bin:/usr/bin:/bin" "$ROOT/bin/last-stack-gh-pr-queue-state" EdgeVector/last-stack 123 > "$tmp/out"

grep -q '"isInMergeQueue":false' "$tmp/out"
grep -q -- '-f' "$GH_ARGS"
grep -q 'owner=EdgeVector' "$GH_ARGS"
grep -q 'name=last-stack' "$GH_ARGS"
grep -q 'number=123' "$GH_ARGS"

if PATH="$fake_bin:/usr/bin:/bin" "$ROOT/bin/last-stack-gh-pr-queue-state" EdgeVector/last-stack not-a-number >/dev/null 2>&1; then
  echo "expected non-numeric PR number to fail" >&2
  exit 1
fi

echo "ok"
