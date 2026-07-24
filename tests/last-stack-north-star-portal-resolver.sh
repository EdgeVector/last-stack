#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-portal-resolver-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

portal="$WORK/edgevector/discovery"
source_repo="$WORK/source-discovery"
cache="$WORK/discovery.git"

mkdir -p "$portal/.portal" "$source_repo"
git -C "$source_repo" init -q -b main
printf 'from cache\n' >"$source_repo/marker.txt"
git -C "$source_repo" add marker.txt
git -C "$source_repo" -c user.name='Test' -c user.email='test@example.invalid' commit -q -m 'seed discovery cache'
git clone -q --bare "$source_repo" "$cache"
printf '%s\n' "$cache" >"$portal/.portal/cache"

resolved="$(
  EDGEVECTOR_WORKSPACE="$WORK/edgevector" bash -c \
    '. "$1/harness/north-star/common.sh"; ns_repo_path discovery' _ "$ROOT"
)"

test -f "$resolved/marker.txt"
if [ "$resolved" = "$portal" ]; then
  echo "portal repo resolver returned placeholder portal path" >&2
  exit 1
fi

echo "PASS last-stack-north-star-portal-resolver"
