#!/usr/bin/env bash
# Pin the post-merge repo→app map: a merged Loom or Remote CR must resolve to
# the artifact-backed action, never the unsupported-repo skip path (the era-3
# reverse migration silently no-oped every `remote` merge before this pin
# existed — `remote` had a host-track artifact channel and a
# `.lastgit/artifacts.json` but was missing from `map_repo_to_app`, so
# `handle_departure` marked its CRs handled without ever building or
# publishing anything). `--map` prints the table and exits before any
# state-dir or lastgit access, so this test touches no shared state and
# mutates nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

map_out="$("$ROOT/bin/last-stack-post-merge-safe-upgrade" --map)"

printf '%s\n' "$map_out" | grep -q '^loom[[:space:]]*-> artifact:loom$' \
  || fail "loom is not mapped to artifact:loom in --map output: $map_out"

printf '%s\n' "$map_out" | grep -q '^remote[[:space:]]*-> artifact:remote$' \
  || fail "remote is not mapped to artifact:remote in --map output: $map_out"

printf 'ok: post-merge map pins loom -> artifact:loom, remote -> artifact:remote\n'
