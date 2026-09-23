#!/usr/bin/env bash
# Fixture test for bin/last-stack-pipeline-forge-pr-ledger.
#
# Regression (2026-09-22 papercut burn-down): pipeline-health filed one p0 row
# per observed PR STATE (-pending, -failure, -required-checks, ...), up to five
# rows for one PR, and none closed when the PR merged. The ledger must key by
# repo + PR number, append only on change, attribute a red main to one per-repo
# row, and close its own rows with a live point read once the PR leaves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LEDGER="$ROOT/bin/last-stack-pipeline-forge-pr-ledger"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

fx="$tmp/forge"
mkdir -p "$fx" "$tmp/brain"

# ── fake forge: path → fixture file ───────────────────────────────────────────
cat >"$tmp/forge-api" <<'SH'
#!/usr/bin/env bash
path="$1"
key="$(printf '%s' "$path" | tr '/?&=' '____')"
f="$FAKE_FORGE_DIR/$key.json"
if [ -f "$f" ]; then cat "$f"; exit 0; fi
echo "HTTP 404 GET $path" >&2
exit 1
SH
chmod +x "$tmp/forge-api"

# ── fake brain: records keyed by slug; logs every call ───────────────────────
cat >"$tmp/brain-bin" <<'SH'
#!/usr/bin/env bash
db="$FAKE_BRAIN_DIR"
echo "$*" >>"$db/calls.log"
case "$1" in
  get)
    slug="$2"
    if [ -f "$db/$slug.status" ]; then
      printf '{"slug":"%s","status":"%s"}\n' "$slug" "$(cat "$db/$slug.status")"; exit 0
    fi
    echo "{\"error\":\"No papercut: $slug\"}"; echo "error: No papercut: $slug" >&2; exit 1 ;;
  append)
    cat >>"$db/$2.body"; exit 0 ;;
  papercut)
    case "$2" in
      file)
        slug="$3"
        if [ -f "$db/refuse-once" ] && ! printf '%s' "$*" | grep -q -- '--not-duplicate-of'; then
          echo "refused: similar live papercut papercut-pipeline-forge-fold-pr-9" >&2; exit 1
        fi
        echo open >"$db/$slug.status"; exit 0 ;;
      close)
        slug="$3"; shift 3
        while [ "$#" -gt 0 ]; do
          case "$1" in --status) echo "$2" >"$db/$slug.status"; shift 2 ;; *) shift ;; esac
        done
        exit 0 ;;
    esac ;;
esac
echo "unexpected brain call: $*" >&2
exit 2
SH
chmod +x "$tmp/brain-bin"

export FAKE_FORGE_DIR="$fx" FAKE_BRAIN_DIR="$tmp/brain"
export LAST_STACK_FORGE_API="$tmp/forge-api"
export LAST_STACK_PR_LEDGER_NOW="2026-09-22T12:00:00Z"
put() { key="$(printf '%s' "$1" | tr '/?&=' '____')"; cat >"$fx/$key.json"; }

R=EdgeVector/fold
put "repos/$R/branch_protections" <<'J'
[{"rule_name":"main","enable_status_check":true,"status_check_contexts":["Forge CI / ci-required (pull_request)","Forge CI / Mini (pull_request)"]}]
J
put "repos/$R/branches/main" <<'J'
{"commit":{"id":"base1"}}
J
put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"success","created_at":"2026-09-22T11:00:00Z"}]}
J
pulls_open() { # pulls_open <n...>: open PR rows, each red on Mini since 10:00
  local first=1
  printf '['
  for n in "$@"; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"number":%s,"state":"open","title":"t%s","mergeable":true,"created_at":"2026-09-22T10:00:00Z","updated_at":"2026-09-22T10:00:00Z","head":{"ref":"kanban/x%s","sha":"head%s"},"base":{"ref":"main"}}' "$n" "$n" "$n" "$n"
  done
  printf ']\n'
}
pulls_open 7 | put "repos/$R/pulls?state=open&limit=50"
put "repos/$R/commits/head7/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","created_at":"2026-09-22T10:10:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"pending","created_at":"2026-09-22T10:05:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"failure","created_at":"2026-09-22T10:20:00Z"}]}
J

# fake board: card "x7" (PR 7's branch kanban/x7) is unowned unless OWNED_CARD names it
cat >"$tmp/kanban-bin" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] || exit 2
if [ "${OWNED_CARD:-}" = "$2" ]; then
  printf '{"slug":"%s","column":"doing","assignee":"worker-1","updated_at":"2026-09-22T11:50:00Z"}\n' "$2"; exit 0
fi
printf '{"slug":"%s","column":"todo","assignee":"","updated_at":"2026-09-20T00:00:00Z"}\n' "$2"
SH
chmod +x "$tmp/kanban-bin"

state="$tmp/state.json"
sync() { "$LEDGER" sync --repo "$R" --brain-bin "$tmp/brain-bin" --kanban-bin "$tmp/kanban-bin" --state-file "$state" --json "$@" >"$tmp/out.json"; }

# 0. a red PR whose card is in doing with a fresh worker is that worker's job
OWNED_CARD=x7 sync --apply
jq -e '.ledger.actions == [{"action":"owned","slug":"papercut-pipeline-forge-fold-pr-7","card":"x7"}]' "$tmp/out.json" >/dev/null \
  || { echo "FAIL owned PR must not be filed"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status" ] || { echo "FAIL owned PR filed"; exit 1; }
echo "ok   a PR owned by a fresh doing card is not filed"

# 1. scan reads branch protection and takes the NEWEST status per context
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.prs[0].shape == "red" and .prs[0].stuck == true and .prs[0].red_contexts == ["Forge CI / Mini"]
       and .prs[0].ledger_slug == "papercut-pipeline-forge-fold-pr-7" and .prs[0].root_cause == ""' "$tmp/scan.json" >/dev/null \
  || { echo "FAIL scan classification"; cat "$tmp/scan.json"; exit 1; }
echo "ok   scan: required contexts from branch protection, newest status wins"

# 2. dry run writes nothing
sync
jq -e '.ledger.apply == false and .ledger.actions[0].action == "file"' "$tmp/out.json" >/dev/null || { echo "FAIL dry run"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status" ] || { echo "FAIL dry run filed"; exit 1; }
echo "ok   sync without --apply is a dry run"

# 3. first apply files ONE row keyed by PR number
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status")" = open ] || { echo "FAIL not filed"; exit 1; }
echo "ok   apply files papercut-pipeline-forge-fold-pr-7"

# 4. same head + same shape → no second write (no per-state sibling, no append)
: >"$tmp/brain/calls.log"
sync --apply
jq -e '.ledger.actions == [{"action":"unchanged","slug":"papercut-pipeline-forge-fold-pr-7"}]' "$tmp/out.json" >/dev/null \
  || { echo "FAIL repeat pass must be unchanged"; cat "$tmp/out.json"; exit 1; }
if grep -Eq '^(append|papercut file)' "$tmp/brain/calls.log"; then echo "FAIL repeat pass wrote"; cat "$tmp/brain/calls.log"; exit 1; fi
echo "ok   an unchanged PR causes no write"

# 5. a new head appends ONE evidence line to the same slug
pulls_open 7 | sed 's/"sha":"head7"/"sha":"head7b"/' | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head7b_status.json"
sync --apply
jq -e '.ledger.actions[0].action == "append"' "$tmp/out.json" >/dev/null || { echo "FAIL new head must append"; cat "$tmp/out.json"; exit 1; }
grep -q 'head=head7b' "$tmp/brain/papercut-pipeline-forge-fold-pr-7.body" || { echo "FAIL evidence line"; exit 1; }
echo "ok   a changed head appends to the same row"

# 6. PR merged → the row closes verified with the point read
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
put "repos/$R/pulls/7" <<'J'
{"number":7,"state":"closed","merged":true,"merged_at":"2026-09-22T11:59:00Z"}
J
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status")" = verified ] || { echo "FAIL merged PR row not closed"; cat "$tmp/out.json"; exit 1; }
grep -q 'papercut close papercut-pipeline-forge-fold-pr-7 --status verified' "$tmp/brain/calls.log" || { echo "FAIL close call"; exit 1; }
jq -e '.ledger.tracked == []' "$tmp/out.json" >/dev/null || { echo "FAIL tracked not pruned"; exit 1; }
echo "ok   merged PR closes its own row verified"

# 7. main red on the same context → one per-repo main-red row, no per-PR rows
put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"failure","created_at":"2026-09-22T11:00:00Z"}]}
J
pulls_open 8 9 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head8_status.json"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head9_status.json"
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-main-red.status")" = open ] || { echo "FAIL main-red row"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-8.status" ] || { echo "FAIL per-PR row under red main"; exit 1; }
jq -e '[.ledger.actions[] | select(.action=="file")] | length == 1' "$tmp/out.json" >/dev/null || { echo "FAIL one file"; exit 1; }
echo "ok   red main is one per-repo row, not one row per PR"

# 8. main green again → main-red row closes verified
put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"success","created_at":"2026-09-22T11:30:00Z"}]}
J
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-main-red.status")" = verified ] || { echo "FAIL main-red close"; cat "$tmp/out.json"; exit 1; }
echo "ok   green main closes the main-red row verified"

# 9. dedupe gate refusal naming only sibling PR rows is cleared precisely
touch "$tmp/brain/refuse-once"
pulls_open 10 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head10_status.json"
sync --apply
grep -q -- '--not-duplicate-of papercut-pipeline-forge-fold-pr-9' "$tmp/brain/calls.log" || { echo "FAIL sibling clear"; cat "$tmp/out.json"; exit 1; }
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-10.status")" = open ] || { echo "FAIL pr-10 file"; exit 1; }
echo "ok   dedupe refusal on a sibling PR row is cleared by name"

# 9b. a row closed as duplicate of a root cause is respected, not re-filed
echo duplicate >"$tmp/brain/papercut-pipeline-forge-fold-pr-10.status"
pulls_open 10 | sed 's/"sha":"head10"/"sha":"head10b"/' | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head10b_status.json"
: >"$tmp/brain/calls.log"
sync --apply
jq -e '.ledger.actions[0].action == "attributed"' "$tmp/out.json" >/dev/null || { echo "FAIL duplicate attribution"; cat "$tmp/out.json"; exit 1; }
if grep -q '^papercut file' "$tmp/brain/calls.log"; then echo "FAIL re-filed a duplicate-attributed PR"; exit 1; fi
echo "ok   a duplicate-attributed PR row is not re-filed"

# 9c. a PR red only on a context a LIVE named root cause owns → evidence there
printf 'EdgeVector/fold\tForge CI / Mini (pull_request)\tpapercut-known-mini-flake\n' >"$tmp/root-causes.tsv"
echo open >"$tmp/brain/papercut-known-mini-flake.status"
pulls_open 11 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head11_status.json"
: >"$tmp/brain/calls.log"
sync --apply --root-causes-file "$tmp/root-causes.tsv"
jq -e '([.ledger.actions[] | select(.action=="append" and .slug=="papercut-known-mini-flake")] | length) == 1
       and ([.ledger.actions[] | select(.action=="file")] | length) == 0' "$tmp/out.json" >/dev/null \
  || { echo "FAIL known root cause must take the evidence"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-11.status" ] || { echo "FAIL per-PR row filed under a known root cause"; exit 1; }
# the root cause is never closed by the ledger, even when its PRs leave
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
sync --apply --root-causes-file "$tmp/root-causes.tsv"
[ "$(cat "$tmp/brain/papercut-known-mini-flake.status")" = open ] || { echo "FAIL ledger closed a root cause it does not own"; exit 1; }
# once the root cause is closed, a PR red on that context gets its own row again
echo verified >"$tmp/brain/papercut-known-mini-flake.status"
pulls_open 12 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head12_status.json"
sync --apply --root-causes-file "$tmp/root-causes.tsv"
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-12.status" 2>/dev/null)" = open ] || { echo "FAIL closed root cause must stop absorbing PRs"; cat "$tmp/out.json"; exit 1; }
echo "ok   a live named root cause absorbs PRs red only on its context"

# 10. the prompt uses the ledger and forbids per-state slugs
grep -Fq 'last-stack-pipeline-forge-pr-ledger" sync --apply' "$ROOT/routines/pipeline-health.md" \
  || { echo "FAIL pipeline-health.md must run the ledger"; exit 1; }
echo "ok   pipeline-health.md runs the ledger"

echo "PASS last-stack-pipeline-forge-pr-ledger"
