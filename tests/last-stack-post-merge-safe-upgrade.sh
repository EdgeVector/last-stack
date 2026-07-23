#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

map_out="$("$ROOT/bin/last-stack-post-merge-safe-upgrade" --map)"
printf '%s\n' "$map_out" | grep -q '^last-stack[[:space:]]*-> artifact:last-stack$' \
  || fail "last-stack is not mapped to the artifact-backed post-merge action"

mkdir -p "$tmp/bin" "$tmp/state"
cat >"$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = cr ] && [ "$2" = list ] && [ "${3:-}" = --all-open ]; then
  printf '[]\n'
  exit 0
fi

if [ "$1" = cr ] && [ "$2" = view ] && [ "$3" = last-stack ] && [ "$4" = cr-test ]; then
  cat <<'JSON'
{
  "cr_id": "cr-test",
  "repo": "last-stack",
  "state": "merged",
  "base_ref": "refs/heads/main",
  "head_oid": "1111111111111111111111111111111111111111",
  "merge_oid": "2222222222222222222222222222222222222222"
}
JSON
  exit 0
fi

printf 'unexpected lastgit args: %s\n' "$*" >&2
exit 2
SH
chmod +x "$tmp/bin/lastgit"

printf 'last-stack:cr-test\n' >"$tmp/state/fleet.open"

PATH="$tmp/bin:$PATH" \
  LAST_STACK_POST_MERGE_DRY_RUN=1 \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge.log" \
  "$ROOT/bin/last-stack-post-merge-safe-upgrade" --once --all "$tmp/state" >/dev/null

grep -q 'DRY_RUN: would promote last-stack artifact and refresh host-track repo=last-stack cr=cr-test oid=2222222222222222222222222222222222222222' \
  "$tmp/post-merge.log" || fail "dry-run log did not promote the merge OID"
grep -qx 'cr-test' "$tmp/state/last-stack.handled" \
  || fail "last-stack CR was not marked handled after artifact action"

printf 'ok: last-stack post-merge artifact upgrade\n'
