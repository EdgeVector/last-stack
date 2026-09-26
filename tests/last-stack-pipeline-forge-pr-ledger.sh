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

# ── fake situations: OK unless BLOCKED_REPO names the repo ───────────────────
# Exported for EVERY case: without it the ledger resolves the real `situations`
# through PATH and a fixture test reads the live policy store.
cat >"$tmp/situations-bin" <<'SH'
#!/usr/bin/env bash
# preflight --action <a> --repo <r> --field slug,reason
repo=""; action=""
while [ "$#" -gt 0 ]; do
  case "$1" in --repo) repo="$2"; shift 2 ;; --action) action="$2"; shift 2 ;; *) shift ;; esac
done
if [ "${SITUATIONS_UNREADABLE:-}" = "$repo" ]; then echo "boom" >&2; exit 1; fi
if [ "${BLOCKED_REPO:-}" = "$repo" ] && [ "$action" = merge-pr ]; then
  printf '%s\t%s\n' "${BLOCKED_SLUG:-test-hold-20260926}" blocked; exit 3
fi
exit 0
SH
chmod +x "$tmp/situations-bin"

export FAKE_FORGE_DIR="$fx" FAKE_BRAIN_DIR="$tmp/brain"
export LAST_STACK_FORGE_API="$tmp/forge-api"
export LAST_STACK_SITUATIONS_BIN="$tmp/situations-bin"
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
jq -e '.heartbeat_fields | test("^open_forge=1 stuck=1 stuck_prs=fold#7 unreadable=-$")' "$tmp/scan.json" >/dev/null \
  || { echo "FAIL heartbeat_fields"; jq -r .heartbeat_fields "$tmp/scan.json"; exit 1; }
echo "ok   scan: required contexts from branch protection, newest status wins"

# 2. dry run writes nothing
sync
jq -e '.ledger.apply == false and .ledger.actions[0].action == "file"' "$tmp/out.json" >/dev/null || { echo "FAIL dry run"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status" ] || { echo "FAIL dry run filed"; exit 1; }
echo "ok   sync without --apply is a dry run"

# 3. first apply files ONE row keyed by PR number
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-7.status")" = open ] || { echo "FAIL not filed"; exit 1; }
jq -e '.heartbeat_fields | test("filed_papercut=papercut-pipeline-forge-fold-pr-7 ")' "$tmp/out.json" >/dev/null \
  || { echo "FAIL heartbeat_fields must name the filed row"; jq -r .heartbeat_fields "$tmp/out.json"; exit 1; }
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

# ── 8b-8e. a CANCELLED required run is infra, not a product red ───────────────
# papercut-fold-ci-required-cancelled-run-stored-as-a-required-red-20260925:
# the forge stores a cancelled run as `failure` with the description
# "Has been cancelled". Only the description tells the two apart, and before
# this classification every consumer read a red the commit never earned.
cancelled_base() { # cancelled_base <desc-for-Mini>
  put "repos/$R/commits/base1/status" <<J
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"failure","description":"$1","created_at":"2026-09-22T11:00:00Z"}]}
J
}

# 8b. a base tip whose only red is a cancellation is NOT a red main, so no PR
#     is attributed to it and no main-red row is filed.
cancelled_base "Has been cancelled"
pulls_open 40 | put "repos/$R/pulls?state=open&limit=50"
cat >"$fx/repos_EdgeVector_fold_commits_head40_status.json" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","created_at":"2026-09-22T10:10:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"failure","description":"Has been cancelled","created_at":"2026-09-22T10:20:00Z"}]}
J
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.repos[0].base.main.verdict == "cancelled" and .repos[0].base.main.red_contexts == []
       and .repos[0].base.main.cancelled_contexts == ["Forge CI / Mini"]' "$tmp/scan.json" >/dev/null   || { echo "FAIL cancelled base must not be a red main"; jq .repos "$tmp/scan.json"; exit 1; }
jq -e '.prs[0].root_cause == "" and .prs[0].ledger_slug == "papercut-pipeline-forge-fold-pr-40"' "$tmp/scan.json" >/dev/null   || { echo "FAIL a cancelled base must not absorb PRs into main-red"; jq .prs "$tmp/scan.json"; exit 1; }
echo "ok   a base tip red only on a cancelled run is not a red main"

# 8c. the PR itself is shape=cancelled, still stuck, and its row names the re-run
jq -e '.prs[0].shape == "cancelled" and .prs[0].stuck == true and .prs[0].red_contexts == []
       and .prs[0].cancelled_contexts == ["Forge CI / Mini"]' "$tmp/scan.json" >/dev/null   || { echo "FAIL cancelled PR classification"; jq .prs "$tmp/scan.json"; exit 1; }
: >"$tmp/brain/calls.log"
sync --apply
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-40.status")" = open ] || { echo "FAIL cancelled PR not filed"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-main-red.status.new" ] || true
grep -q -- '--title Pipeline: EdgeVector/fold PR 40 is stuck on a CANCELLED required run (re-run it)' "$tmp/brain/calls.log"   || { echo "FAIL cancelled row must name the re-run in its title"; cat "$tmp/brain/calls.log"; exit 1; }
grep -q -- 'the remedy is a re-run, not a code change' "$tmp/brain/calls.log"   || { echo "FAIL cancelled row must name the remedy in its symptom"; cat "$tmp/brain/calls.log"; exit 1; }
grep -q 'cancelled=Forge CI / Mini' "$tmp/brain/calls.log"   || { echo "FAIL evidence line must name the cancelled contexts"; cat "$tmp/brain/calls.log"; exit 1; }
echo "ok   a cancelled PR is stuck, filed on its own, and names the re-run"

# 8d. a REAL red outranks a cancellation: the commit earned the red, and the
#     cancelled context must not soften it (fold f045a0b83223 is this shape).
put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"success","created_at":"2026-09-22T11:30:00Z"}]}
J
pulls_open 41 | put "repos/$R/pulls?state=open&limit=50"
cat >"$fx/repos_EdgeVector_fold_commits_head41_status.json" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"failure","description":"Has been cancelled","created_at":"2026-09-22T10:10:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"failure","description":"Failing after 14m24s","created_at":"2026-09-22T10:20:00Z"}]}
J
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.prs[0].shape == "red" and .prs[0].red_contexts == ["Forge CI / Mini"]
       and .prs[0].cancelled_contexts == ["Forge CI / ci-required"]' "$tmp/scan.json" >/dev/null   || { echo "FAIL a real red must outrank a cancellation"; jq .prs "$tmp/scan.json"; exit 1; }
echo "ok   a real red outranks a cancellation on the same commit"

# 8e. only the DESCRIPTION distinguishes them: the same status value with an
#     ordinary failure description stays a product red. This is the assertion
#     that fails if anyone widens the match to the status value.
cancelled_base "Failing after 15m27s"
pulls_open 42 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head40_status.json" "$fx/repos_EdgeVector_fold_commits_head42_status.json"
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.repos[0].base.main.verdict == "red" and .repos[0].base.main.red_contexts == ["Forge CI / Mini"]
       and .repos[0].base.main.cancelled_contexts == []' "$tmp/scan.json" >/dev/null   || { echo "FAIL a failure without a cancel description is still a product red"; jq .repos "$tmp/scan.json"; exit 1; }
echo "ok   a failure whose description is not a cancellation stays a red main"

# reset the board for the cases that follow
put "repos/$R/commits/base1/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (push)","status":"success","created_at":"2026-09-22T11:00:00Z"},
             {"context":"Forge CI / Mini (push)","status":"success","created_at":"2026-09-22T11:30:00Z"}]}
J
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
put "repos/$R/pulls/40" <<'J'
{"number":40,"state":"closed","merged":true,"merged_at":"2026-09-22T11:59:00Z"}
J
sync --apply >/dev/null 2>&1 || true

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

# 9d. reap-plan: guard verdict + fresh point read per over-age PR, no loop needed
cat >"$tmp/guard-bin" <<'SH'
#!/usr/bin/env bash
# fake close guard: PR 13 is close-ok, anything else refuses
pr=""; while [ "$#" -gt 0 ]; do case "$1" in --pr) pr="$2"; shift 2 ;; *) shift ;; esac; done
if [ "$pr" = 13 ]; then echo '{"verdict":"close-ok","reason":"required-check-failed"}'; exit 0; fi
echo '{"verdict":"refuse","reason":"green-unmerged-auto-merge"}'; exit 1
SH
chmod +x "$tmp/guard-bin"
pulls_open 13 14 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head13_status.json"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head14_status.json"
put "repos/$R/pulls/13" <<'J'
{"number":13,"state":"open","merged":false,"head":{"sha":"head13"}}
J
put "repos/$R/pulls/14" <<'J'
{"number":14,"state":"closed","merged":true,"head":{"sha":"head14"}}
J
LAST_STACK_CLOSE_GUARD="$tmp/guard-bin" "$LEDGER" reap-plan --repo "$R" --json >"$tmp/plan.json"
jq -e '[.reap_plan[] | select(.number==13)][0] | .guard_verdict=="close-ok" and .may_close==true and .head_unchanged==true' "$tmp/plan.json" >/dev/null \
  || { echo "FAIL reap-plan must allow closing a guarded, still-open PR"; cat "$tmp/plan.json"; exit 1; }
jq -e '[.reap_plan[] | select(.number==14)][0] | .may_close==false and .point.merged==true' "$tmp/plan.json" >/dev/null \
  || { echo "FAIL reap-plan must not close a PR the point read shows merged"; cat "$tmp/plan.json"; exit 1; }
echo "ok   reap-plan pairs each over-age PR with its guard verdict and a fresh point read"

# 9e. a GREEN unmerged PR: armed is a defect, unarmed is somebody's decision
#     Regression 2026-09-25: EdgeVector/routines#36 was green and mergeable for
#     103 minutes because its loom land-card execution PARKED ("review escalated
#     at cap") and its card sat in needs_human. Nobody armed auto-merge, so
#     nothing would ever merge it — and the ledger filed a p0 pipeline row that
#     could never close, while `merge-green` on the same PR answered
#     `green-not-armed` ("Nobody asked for a merge"). The two halves of this
#     helper have to agree.
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
sync --apply   # drain the tracked rows from the cases above
pulls_open 20 | put "repos/$R/pulls?state=open&limit=50"
put "repos/$R/commits/head20/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","created_at":"2026-09-22T10:10:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"success","created_at":"2026-09-22T10:20:00Z"}]}
J
# the timeline says nobody ever armed a schedule
put "repos/$R/issues/20/timeline?limit=50&page=1" <<'J'
[{"type":"comment","created_at":"2026-09-22T10:30:00Z"}]
J
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.prs[0].shape == "green-unmerged" and .prs[0].merge_intent == "unarmed"
       and .prs[0].stuck == false and .prs[0].stuck_excluded == "green-unarmed"' "$tmp/scan.json" >/dev/null   || { echo "FAIL an unarmed green PR must not be stuck"; cat "$tmp/scan.json"; exit 1; }
jq -e '.heartbeat_fields | test("stuck=0 ") and test("green_unarmed=fold#20")' "$tmp/scan.json" >/dev/null   || { echo "FAIL heartbeat must RECORD the unarmed green PR"; jq -r .heartbeat_fields "$tmp/scan.json"; exit 1; }
: >"$tmp/brain/calls.log"
sync --apply
jq -e '([.ledger.actions[] | select(.action=="green-unarmed" and .slug=="papercut-pipeline-forge-fold-pr-20")] | length) == 1
       and ([.ledger.actions[] | select(.action=="file")] | length) == 0' "$tmp/out.json" >/dev/null   || { echo "FAIL sync must name the unarmed green PR and file nothing"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-20.status" ] || { echo "FAIL filed a p0 for a PR nobody armed"; exit 1; }
echo "ok   a green PR nobody armed is recorded, not filed"

# same PR, now ARMED: Forgejo never fires a schedule armed after green, so this
# one IS stuck, and its evidence line has to say which repair applies.
put "repos/$R/issues/20/timeline?limit=50&page=1" <<'J'
[{"type":"pull_scheduled_merge","created_at":"2026-09-22T10:30:00Z"}]
J
sync --apply
jq -e '.ledger.actions[0].action == "file" and .ledger.actions[0].slug == "papercut-pipeline-forge-fold-pr-20"' "$tmp/out.json" >/dev/null   || { echo "FAIL an armed green PR must be filed"; cat "$tmp/out.json"; exit 1; }
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-20.status")" = open ] || { echo "FAIL armed green PR not filed"; exit 1; }
grep -Fq 'shape=green-unmerged intent=armed' "$tmp/brain/calls.log"   || { echo "FAIL evidence must name the merge intent"; cat "$tmp/brain/calls.log"; exit 1; }
echo "ok   an armed green PR is filed and its evidence names the intent"

# an UNREADABLE timeline must not silence the row
put "repos/$R/issues/20/timeline?limit=50&page=1" <<'J'
{"message":"boom"}
J
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.prs[0].merge_intent == "unknown" and .prs[0].stuck == true' "$tmp/scan.json" >/dev/null   || { echo "FAIL an unreadable timeline must stay stuck"; cat "$tmp/scan.json"; exit 1; }
echo "ok   an unreadable arm probe stays stuck"

# a red PR never pays for the timeline read
rm -f "$fx/repos_EdgeVector_fold_issues_20_timeline?limit=50&page=1.json"       "$fx/repos_EdgeVector_fold_issues_20_timeline_limit_50_page_1.json"
pulls_open 21 | put "repos/$R/pulls?state=open&limit=50"
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head21_status.json"
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '.prs[0].shape == "red" and .prs[0].merge_intent == "" and .prs[0].stuck == true' "$tmp/scan.json" >/dev/null   || { echo "FAIL a red PR must not read the arm state"; cat "$tmp/scan.json"; exit 1; }
echo "ok   merge_intent is read only for a green PR"

# 9f. a green PR whose repo is under a Situation that blocks merge-pr
#     Regression 2026-09-25: the ledger filed p0 papercut-pipeline-forge-loom-pr-63
#     for a green, mergeable PR whose only blocker was
#     loom-budget-schema-deployment-hold-20260925 (merge-pr in blocked_actions,
#     EdgeVector/loom in scope_repos). A p0 whose implied remedy is an action an
#     active p0 Situation forbids raises papercut-p0-active, puts a deliberate
#     hold at the top of the factory queue, and invites the merge: three loom PRs
#     merged under that hold the same day.
echo '[]' | put "repos/$R/pulls?state=open&limit=50"
sync --apply   # drain the tracked rows from the cases above
# PR 30 green + ARMED (so it is stuck but for the hold), PR 31 red on the same repo
pulls_open 30 31 | put "repos/$R/pulls?state=open&limit=50"
put "repos/$R/commits/head30/status" <<'J'
{"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success","created_at":"2026-09-22T10:10:00Z"},
             {"context":"Forge CI / Mini (pull_request)","status":"success","created_at":"2026-09-22T10:20:00Z"}]}
J
cp "$fx/repos_EdgeVector_fold_commits_head7_status.json" "$fx/repos_EdgeVector_fold_commits_head31_status.json"
put "repos/$R/issues/30/timeline?limit=50&page=1" <<'J'
[{"type":"pull_scheduled_merge","created_at":"2026-09-22T10:30:00Z"}]
J

# control: with no hold, the armed green PR IS stuck
"$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '(.prs[] | select(.number==30) | .stuck) == true
       and (.prs[] | select(.number==30) | .merge_policy) == "ok"
       and (.prs[] | select(.number==31) | .merge_policy) == ""' "$tmp/scan.json" >/dev/null   || { echo "FAIL control: an armed green PR on an unheld repo must stay stuck, and a red PR must not pay for the policy read"; cat "$tmp/scan.json"; exit 1; }

BLOCKED_REPO="$R" BLOCKED_SLUG=hold-abc-20260926 "$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '(.prs[] | select(.number==30) | .stuck) == false
       and (.prs[] | select(.number==30) | .stuck_excluded) == "policy-blocked"
       and (.prs[] | select(.number==30) | .policy_hold) == "hold-abc-20260926"' "$tmp/scan.json" >/dev/null   || { echo "FAIL a green PR on a merge-pr-blocked repo must not be stuck"; cat "$tmp/scan.json"; exit 1; }
# the SAME pass must keep the red PR stuck: a held repo's broken CI lane is
# still a pipeline defect, and drafting its fix is inside the hold's
# allowed_actions. A fixture with only the green case cannot tell a correctly
# scoped check from one that suppresses every shape.
jq -e '(.prs[] | select(.number==31) | .stuck) == true
       and (.prs[] | select(.number==31) | .stuck_excluded) == ""' "$tmp/scan.json" >/dev/null   || { echo "FAIL a red PR on a held repo is still a pipeline defect"; cat "$tmp/scan.json"; exit 1; }
jq -e '.heartbeat_fields | test("policy_blocked=fold#30") and test("policy_holds=hold-abc-20260926")' "$tmp/scan.json" >/dev/null   || { echo "FAIL heartbeat must RECORD the held PR and name the hold"; jq -r .heartbeat_fields "$tmp/scan.json"; exit 1; }
: >"$tmp/brain/calls.log"
BLOCKED_REPO="$R" BLOCKED_SLUG=hold-abc-20260926 sync --apply
jq -e '([.ledger.actions[] | select(.action=="policy-blocked" and .slug=="papercut-pipeline-forge-fold-pr-30" and .policy=="hold-abc-20260926")] | length) == 1
       and ([.ledger.actions[] | select(.action=="file" and .slug=="papercut-pipeline-forge-fold-pr-31")] | length) == 1' "$tmp/out.json" >/dev/null   || { echo "FAIL sync must name the held PR and still file the red one"; cat "$tmp/out.json"; exit 1; }
[ ! -f "$tmp/brain/papercut-pipeline-forge-fold-pr-30.status" ] || { echo "FAIL filed a p0 for a PR an active hold forbids merging"; exit 1; }
[ "$(cat "$tmp/brain/papercut-pipeline-forge-fold-pr-31.status")" = open ] || { echo "FAIL red PR on a held repo was suppressed too"; exit 1; }
echo "ok   a green PR under a merge-pr hold is recorded, not filed; a red one still is"

# an UNREADABLE policy store must FILE, not suppress. The opposite asymmetry to
# merge_green_once: a filing writes nothing to the forge, so failing closed here
# would lose a real signal for no gain.
SITUATIONS_UNREADABLE="$R" "$LEDGER" scan --repo "$R" --json >"$tmp/scan.json"
jq -e '(.prs[] | select(.number==30) | .stuck) == true
       and (.prs[] | select(.number==30) | .merge_policy) == "unreadable"' "$tmp/scan.json" >/dev/null   || { echo "FAIL an unreadable merge-pr policy must fail OPEN and stay stuck"; cat "$tmp/scan.json"; exit 1; }
echo "ok   an unreadable policy store fails open"

# 10. the prompt uses the ledger and forbids per-state slugs
grep -Fq 'last-stack-pipeline-forge-pr-ledger" reap-plan' "$ROOT/routines/pr-reaper.md" \
  || { echo "FAIL pr-reaper.md must read the reap plan"; exit 1; }
grep -Fq 'last-stack-pipeline-forge-pr-ledger" sync --apply' "$ROOT/routines/pipeline-health.md" \
  || { echo "FAIL pipeline-health.md must run the ledger"; exit 1; }
echo "ok   pipeline-health.md runs the ledger"

echo "PASS last-stack-pipeline-forge-pr-ledger"
