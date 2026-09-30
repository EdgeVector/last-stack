#!/usr/bin/env bash
# The post-merge worker reads merged GitHub PRs (gh) and refreshes the mapped
# host-track artifact app. Stubs stand in for gh and host-track; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORKER="$ROOT/bin/last-stack-post-merge-safe-upgrade"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-post-merge-test.XXXXXX")"
cleanup() { [ -n "${KEEP:-}" ] || rm -rf "$tmp"; }
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

map_out="$("$WORKER" --map)"
printf '%s\n' "$map_out" | grep -q '^last-stack[[:space:]]*-> artifact:last-stack$' \
  || fail "last-stack is not mapped to the artifact action"
printf '%s\n' "$map_out" | grep -q '^loom[[:space:]]*-> artifact:loom$' \
  || fail "loom is not mapped to the artifact action"

mkdir -p "$tmp/bin" "$tmp/state"
# gh stub: `gh pr list -R EdgeVector/<repo> ...` prints rows from $GH_ROWS_DIR/<repo>.
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = pr ] && [ "${2:-}" = list ] || { printf 'unexpected gh args: %s\n' "$*" >&2; exit 2; }
repo=""
while [ $# -gt 0 ]; do
  case "$1" in -R) repo="${2#EdgeVector/}"; shift 2 ;; *) shift ;; esac
done
[ -f "$GH_ROWS_DIR/$repo" ] && cat "$GH_ROWS_DIR/$repo"
exit 0
SH
cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  refresh) printf '%s\n' "${2:-}" >>"$HT_REFRESH_LOG"; [ ! -f "$HT_REFRESH_FAIL" ] || exit 1 ;;
  status) app="${3:-}"; if [ -f "$HT_STALE_DIR/$app" ]; then
      printf '{"install_mode":"artifact","stale":true,"main_unpublished":false}\n'
    else printf '{"install_mode":"artifact","stale":false,"main_unpublished":false}\n'; fi ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/host-track"
mkdir -p "$tmp/rows" "$tmp/stale"
: >"$tmp/refresh.log"

run_worker() {
  env PATH="$tmp/bin:$PATH" \
    GH_ROWS_DIR="$tmp/rows" HT_REFRESH_LOG="$tmp/refresh.log" \
    HT_REFRESH_FAIL="$tmp/refresh-fail" HT_STALE_DIR="$tmp/stale" \
    LAST_STACK_POST_MERGE_LOG="$tmp/post-merge.log" \
    LAST_STACK_POST_MERGE_MAX_ATTEMPTS=2 \
    LAST_STACK_POST_MERGE_CONVERGE_INTERVAL=0 \
    "$WORKER" --once --all "$tmp/state" >/dev/null 2>&1
}

# Pass 1 seeds: existing merged PRs are history, never upgraded.
printf '7\t%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$tmp/rows/last-stack"
printf '3\t%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$tmp/rows/loom"
run_worker
[ ! -s "$tmp/refresh.log" ] || fail "seed pass refreshed history"
grep -qx '7' "$tmp/state/last-stack.handled" || fail "seed did not record last-stack #7"

# Pass 2: a new merged PR on loom refreshes loom only, once.
printf '3\t%s\n4\t%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc >"$tmp/rows/loom"
run_worker
[ "$(cat "$tmp/refresh.log")" = loom ] || fail "new loom merge did not refresh exactly loom: $(cat "$tmp/refresh.log")"
grep -qx '4' "$tmp/state/loom.handled" || fail "loom #4 not marked handled"
run_worker
[ "$(wc -l <"$tmp/refresh.log" | tr -d ' ')" = 1 ] || fail "handled PR refreshed again"

# Pass 3: a failing refresh retries up to the cap, then gives up visibly.
printf '5\t%s\n' dddddddddddddddddddddddddddddddddddddddd >>"$tmp/rows/loom"
: >"$tmp/refresh-fail"
run_worker
grep -q 'FAIL upgrade app=artifact:loom repo=loom pr=5 attempt=1/2' "$tmp/post-merge.log" || fail "first failure not logged"
run_worker
grep -q 'GIVE_UP app=artifact:loom repo=loom pr=5 after 2 attempts' "$tmp/post-merge.log" || fail "give-up not logged"
grep -qx '5' "$tmp/state/loom.handled" || fail "given-up PR not marked handled"
rm -f "$tmp/refresh-fail"

# Convergence: a stale app is refreshed even with no new merge.
: >"$tmp/refresh.log"
: >"$tmp/stale/situations"
run_worker
grep -qx 'situations' "$tmp/refresh.log" || fail "stale situations was not refreshed by the convergence tail"
grep -qx 'brain' "$tmp/refresh.log" && fail "fresh brain was refreshed"

# Dry run logs and does not call host-track refresh.
: >"$tmp/refresh.log"
printf '9\t%s\n' eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee >>"$tmp/rows/last-stack"
env PATH="$tmp/bin:$PATH" GH_ROWS_DIR="$tmp/rows" HT_REFRESH_LOG="$tmp/refresh.log" \
  HT_REFRESH_FAIL="$tmp/refresh-fail" HT_STALE_DIR="$tmp/stale" \
  LAST_STACK_POST_MERGE_DRY_RUN=1 LAST_STACK_POST_MERGE_CONVERGE=0 \
  LAST_STACK_POST_MERGE_LOG="$tmp/post-merge.log" \
  "$WORKER" --once --all "$tmp/state" >/dev/null 2>&1
grep -q 'DRY_RUN: would refresh host-track last-stack repo=last-stack pr=9' "$tmp/post-merge.log" || fail "dry run did not log"
[ ! -s "$tmp/refresh.log" ] || fail "dry run called host-track refresh"

printf 'ok: post-merge worker refreshes artifact apps from merged GitHub PRs\n'
