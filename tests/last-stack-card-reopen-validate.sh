#!/usr/bin/env bash
# Proof: last-stack-card-reopen-validate re-opens a merged CLOSED-ON-MERGE card
# into doing with its merged pr_url, never into todo/backlog, so pickup never
# claims it as WORK (2026-09-24: a Loom land-card walk claimed such a card and
# IMPLEMENT failed on "agent produced no commit"). Fake board; no LastDB.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$ROOT/bin/last-stack-card-reopen-validate"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export RV_COL="$tmp/col" RV_PR="$tmp/pr" RV_BRANCH="$tmp/branch" RV_BODY="$tmp/body" RV_LOG="$tmp/log" RV_DROP_PR="$tmp/drop-pr"

cat >"$tmp/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show)
    jq -n --arg s "$2" --arg c "$(cat "$RV_COL")" --arg p "$(cat "$RV_PR")" --arg b "$(cat "$RV_BRANCH")" \
      --rawfile body "$RV_BODY" '{slug:$s, column:$c, repo:"EdgeVector/last-stack", pr_url:$p, branch:$b, body:$body}'
    ;;
  move) printf '%s\n' "$*" >>"$RV_LOG"; printf '%s' "$3" >"$RV_COL" ;;
  add)
    printf '%s\n' "$*" >>"$RV_LOG"
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pr-url) [ -f "$RV_DROP_PR" ] || printf '%s' "$2" >"$RV_PR"; shift 2 ;;
        --branch) printf '%s' "$2" >"$RV_BRANCH"; shift 2 ;;
        *) shift ;;
      esac
    done
    ;;
  mark) printf '%s\n' "mark $2" >>"$RV_LOG"; printf '%s\n' "$3" >>"$RV_BODY" ;;
  *) echo "unexpected board call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/kanban"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
reset() {
  printf '%s' done >"$RV_COL"; : >"$RV_PR"; : >"$RV_BRANCH"; : >"$RV_LOG"; rm -f "$RV_DROP_PR"
  printf '%s\n' 'Repo: EdgeVector/last-stack' 'Branch: kanban/harness' '## END STATE' 'live --list has the slug' \
    'HANDOFF: loom exec=lx-1 merged http://forge.example:3300/EdgeVector/last-stack/pulls/168; END STATE not met yet.' \
    'BLOCKED[host-track-last-stack-soak]: host_head=0387208b is PR 167 (http://forge.example:3300/EdgeVector/other/pulls/9)' \
    'CLOSED-ON-MERGE 2026-09-24T02:14:05Z pr=none — card moved to done because a PR merged' >"$RV_BODY"
}
run() { "$helper" harness --board-cli "$tmp/kanban" --reason 'live --list omits the slug; host_head lacks PR 168' "$@"; }
want_pr='http://forge.example:3300/EdgeVector/last-stack/pulls/168'

# 1. done card, empty pr_url: the PR comes from the body, the card lands in doing.
reset
out="$(run)" || fail "reopen failed: $out"
printf '%s\n' "$out" | grep -q "reopened column=doing pr_url=$want_pr" || fail "unexpected output: $out"
[ "$(cat "$RV_COL")" = doing ] || fail "card must land in doing, got $(cat "$RV_COL")"
[ "$(cat "$RV_PR")" = "$want_pr" ] || fail "pr_url must be restored, got $(cat "$RV_PR")"
[ "$(cat "$RV_BRANCH")" = kanban/harness ] || fail "branch must be restored from the Branch: header"
grep -q '^move harness doing$' "$RV_LOG" || fail "expected one move to doing"
if grep -Eq '^move harness (todo|backlog)$' "$RV_LOG"; then fail "a validate-only re-open must never move to todo/backlog"; fi
[ "$(grep -c '^PROOF\[reopened-end-state-unmet\]: ' "$RV_BODY")" = 1 ] || fail "expected one reopen marker"
grep -q "merged $want_pr; validate lane owns closure" "$RV_BODY" || fail "marker must name the merged PR"

# 2. A repeat run is a no-op.
: >"$RV_LOG"
out="$(run)" || fail "repeat run failed: $out"
printf '%s\n' "$out" | grep -q 'unchanged column=doing' || fail "repeat run must be unchanged: $out"
[ ! -s "$RV_LOG" ] || fail "repeat run wrote to the board: $(cat "$RV_LOG")"

# 3. No PR anywhere: refuse, change nothing.
reset
printf '%s\n' 'Repo: EdgeVector/last-stack' '## END STATE' 'x' 'CLOSED-ON-MERGE 2026-09-24T02:14:05Z pr=none' >"$RV_BODY"
rc=0; out="$(run 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "no PR must exit 2, got $rc: $out"
[ ! -s "$RV_LOG" ] || fail "no-PR refusal wrote to the board"
[ "$(cat "$RV_COL")" = done ] || fail "no-PR refusal moved the card"

# 4. --pr-url wins over the body; --dry-run writes nothing.
reset
out="$(run --dry-run --pr-url 'http://forge.example:3300/EdgeVector/last-stack/pulls/170')"
printf '%s\n' "$out" | grep -q 'would-reopen column=done->doing pr_url=http://forge.example:3300/EdgeVector/last-stack/pulls/170' || fail "dry run output: $out"
[ ! -s "$RV_LOG" ] || fail "dry run wrote to the board"

# 5. A pr_url that does not stick is a failure, not a silent success.
reset
touch "$RV_DROP_PR"
rc=0; out="$(run 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "a dropped pr_url must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'did-not-stick' || fail "expected did-not-stick: $out"

printf 'ok: merged cards re-open into doing with pr_url, never into the WORK lane\n'
