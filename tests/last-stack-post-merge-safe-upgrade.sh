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

jq -e '
  .apps[]
  | select(.app == "last-stack")
  | any(.links[];
      .source == "bin/last-stack-post-merge-safe-upgrade"
      and .target == "$HOME/.local/bin/last-stack-post-merge-safe-upgrade")
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "last-stack registry does not publish the post-merge worker"

map_out="$("$ROOT/bin/last-stack-post-merge-safe-upgrade" --map)"
printf '%s\n' "$map_out" | grep -q '^last-stack[[:space:]]*-> artifact:last-stack$' \
  || fail "last-stack is not mapped to the artifact-backed post-merge action"
printf '%s\n' "$map_out" | grep -q '^loom[[:space:]]*-> artifact:loom$' \
  || fail "loom is not mapped to the artifact-backed post-merge action"

mkdir -p "$tmp/bin" "$tmp/state"
cat >"$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = cr ] && [ "$2" = list ] && [ "${3:-}" = --all-open ]; then
  printf '[]\n'
  exit 0
fi

if [ "$1" = cr ] && [ "$2" = view ] && [ "$3" = loom ] && [ "$4" = cr-loom ]; then
  cat <<'JSON'
{
  "cr_id": "cr-loom",
  "repo": "loom",
  "state": "merged",
  "base_ref": "refs/heads/main",
  "head_oid": "3333333333333333333333333333333333333333",
  "merge_oid": "4444444444444444444444444444444444444444"
}
JSON
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

printf 'last-stack:cr-test\nloom:cr-loom\n' >"$tmp/state/fleet.open"

PATH="$tmp/bin:$PATH" \
  LAST_STACK_POST_MERGE_DRY_RUN=1 \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge.log" \
  "$ROOT/bin/last-stack-post-merge-safe-upgrade" --once --all "$tmp/state" >/dev/null

grep -q 'DRY_RUN: would promote last-stack artifact and refresh host-track repo=last-stack cr=cr-test oid=2222222222222222222222222222222222222222' \
  "$tmp/post-merge.log" || fail "dry-run log did not promote the merge OID"
grep -qx 'cr-test' "$tmp/state/last-stack.handled" \
  || fail "last-stack CR was not marked handled after artifact action"

# A merged Loom CR must take the artifact promotion + host-track refresh path,
# not the unsupported-repo silent-handled path (which never logs an action).
grep -q 'DRY_RUN: would host-track refresh loom repo=loom cr=cr-loom' \
  "$tmp/post-merge.log" || fail "loom merge did not take the host-track refresh path"
grep -qx 'cr-loom' "$tmp/state/loom.handled" \
  || fail "loom CR was not marked handled after artifact action"


# --- transient departure: a CR read as `merging` must defer, not burn --------
# The completer holds a CR in `merging` for a moment after it leaves the open
# index. Marking it handled on that read drops the only departure event, so
# the merge is never installed (loom cr-mtgf4rnz-5d48, 2026-08-30).
mkdir -p "$tmp/bin2" "$tmp/state2"
cat >"$tmp/bin2/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = cr ] && [ "$2" = list ] && [ "${3:-}" = --all-open ]; then
  printf '[]\n'
  exit 0
fi
if [ "$1" = cr ] && [ "$2" = view ] && [ "$3" = loom ] && [ "$4" = cr-transient ]; then
  n=0
  [ -f "$TRANSIENT_COUNT_FILE" ] && n="$(cat "$TRANSIENT_COUNT_FILE")"
  n=$((n + 1))
  printf '%s\n' "$n" >"$TRANSIENT_COUNT_FILE"
  if [ "$n" -eq 1 ]; then state=merging; else state=merged; fi
  cat <<JSON
{
  "cr_id": "cr-transient",
  "repo": "loom",
  "state": "$state",
  "base_ref": "refs/heads/main",
  "head_oid": "5555555555555555555555555555555555555555",
  "merge_oid": "6666666666666666666666666666666666666666"
}
JSON
  exit 0
fi
printf 'unexpected lastgit args: %s\n' "$*" >&2
exit 2
SH
chmod +x "$tmp/bin2/lastgit"

printf 'loom:cr-transient\n' >"$tmp/state2/fleet.open"

# Pass 1: the view says merging. Expect defer, key retained, no handled mark.
PATH="$tmp/bin2:$PATH" \
  TRANSIENT_COUNT_FILE="$tmp/state2/view-count" \
  LAST_STACK_POST_MERGE_DRY_RUN=1 \
  LAST_STACK_POST_MERGE_CONVERGE=0 \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge2.log" \
  "$ROOT/bin/last-stack-post-merge-safe-upgrade" --once --all "$tmp/state2" >/dev/null

grep -q 'defer loom cr-transient state=merging' "$tmp/post-merge2.log" \
  || fail "merging CR was not deferred"
if [ -f "$tmp/state2/loom.handled" ] && grep -qx 'cr-transient' "$tmp/state2/loom.handled"; then
  fail "merging CR was marked handled on the transient read"
fi
grep -qx 'loom:cr-transient' "$tmp/state2/fleet.open" \
  || fail "deferred CR fell out of the open snapshot"

# Pass 2: the view says merged. Expect the refresh path plus the handled mark.
PATH="$tmp/bin2:$PATH" \
  TRANSIENT_COUNT_FILE="$tmp/state2/view-count" \
  LAST_STACK_POST_MERGE_DRY_RUN=1 \
  LAST_STACK_POST_MERGE_CONVERGE=0 \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge2.log" \
  "$ROOT/bin/last-stack-post-merge-safe-upgrade" --once --all "$tmp/state2" >/dev/null

grep -q 'DRY_RUN: would host-track refresh loom repo=loom cr=cr-transient' "$tmp/post-merge2.log" \
  || fail "settled merge did not take the refresh path after the defer"
grep -qx 'cr-transient' "$tmp/state2/loom.handled" \
  || fail "settled merge was not marked handled"

printf 'ok: last-stack post-merge artifact upgrade\n'
