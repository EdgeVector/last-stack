#!/usr/bin/env bash
# Pin the post-merge repo→app map: a merged Loom CR must resolve to the
# artifact-backed action, never the unsupported-repo skip path. `--map` prints
# the table and exits before any state-dir or lastgit access, so this test
# touches no shared state and mutates nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

map_out="$("$ROOT/bin/last-stack-post-merge-safe-upgrade" --map)"

printf '%s\n' "$map_out" | grep -q '^loom[[:space:]]*-> artifact:loom$' \
  || fail "loom is not mapped to artifact:loom in --map output: $map_out"

printf 'ok: post-merge map pins loom -> artifact:loom\n'
