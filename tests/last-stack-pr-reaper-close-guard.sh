#!/usr/bin/env bash
# Regression: pr-reaper closed green auto-merge PRs whose head never reached
# main (papercut-lastgit-pr-reaper-closes-green-unmerged-cr, p0). The PR left
# the open inventory while the change was off main. Judged through GitHub
# (gh stub) and Forgejo (forge-api stub); the LastGit CR path is retired.
#
# The guard must refuse exactly that shape and stay out of the way of every
# other close, because most unlanded closes on this fleet are correct: of 51
# auto-merge last-stack CRs closed in the 14 days to 2026-09-05, 37 heads never
# reached main and a 12-row sample of those read 8 failure, 2 absent, 2 success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
guard="$ROOT/bin/last-stack-pr-reaper-close-guard"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

test -x "$guard" || chmod +x "$guard"
bash -n "$guard"

if grep -nE '^[[:space:]]*mapfile ' "$guard" >/dev/null; then
  echo "guard must stay bash-3.2 portable (no mapfile builtin)" >&2
  exit 1
fi

git_bin=/usr/bin/git
[ -x "$git_bin" ] || git_bin="$(command -v git)"

# ── ancestry fixture: main has LANDED; STRAY sits on an unmerged branch ──────
repo="$tmp/repo"
"$git_bin" init --quiet "$repo"
"$git_bin" -C "$repo" config user.email t@example.com
"$git_bin" -C "$repo" config user.name t
echo base > "$repo/f"; "$git_bin" -C "$repo" add f
"$git_bin" -C "$repo" commit --quiet -m base
BASE_PARENT="$("$git_bin" -C "$repo" rev-parse HEAD)"
echo landed > "$repo/f"; "$git_bin" -C "$repo" commit --quiet -am landed
LANDED="$("$git_bin" -C "$repo" rev-parse HEAD)"
MAIN="$LANDED"
"$git_bin" -C "$repo" checkout --quiet -b stray "$BASE_PARENT"
echo stray > "$repo/f"; "$git_bin" -C "$repo" commit --quiet -am stray
STRAY="$("$git_bin" -C "$repo" rev-parse HEAD)"

# ── 14-17. Forgejo PRs go through the same ladder ───────────────────────────
pr_row() { # pr_row <state> <merged> <head>
  cat <<JSON
{"number":7,"state":"$1","merged":$2,"head":{"ref":"kanban/x","sha":"$3"},"base":{"ref":"main","sha":"$MAIN"}}
JSON
}
forge_status() { # forge_status <state> [event]
  cat <<JSON
{"state":"$1","statuses":[
  {"context":"Forge CI / ci-required (${2:-pull_request})","status":"$1","created_at":"2026-09-06T21:00:00Z"},
  {"context":"Forge CI / publish host-track artifact (${2:-pull_request})","status":"pending","created_at":"2026-09-06T21:00:01Z"}]}
JSON
}
run_forge() { # run_forge <label> <verdict> <exit> <pr> <head-status> <base-status>
  local label="$1" want_verdict="$2" want_exit="$3" prj="$4" hs="$5" bs="$6" rc=0
  "$guard" --venue forgejo --repo brain --pr 7 \
    --pr-json "$prj" --head-status-json "$hs" --base-status-json "$bs" \
    --base-oid "$MAIN" --git-dir "$repo" --no-fetch --json \
    >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
  local got
  got="$(jq -r '.verdict' "$tmp/out.json" 2>/dev/null || echo PARSE-FAIL)"
  if [ "$got" != "$want_verdict" ] || [ "$rc" != "$want_exit" ]; then
    echo "FAIL $label: want verdict=$want_verdict exit=$want_exit, got verdict=$got exit=$rc" >&2
    cat "$tmp/out.json" "$tmp/out.err" >&2 || true
    exit 1
  fi
  echo "ok   $label ($got, exit $rc)"
}
pr_row open false "$STRAY" > "$tmp/pr-open.json"
forge_status failure > "$tmp/fs-head-red.json"
forge_status failure push > "$tmp/fs-base-red.json"
forge_status success push > "$tmp/fs-base-green.json"
forge_status success > "$tmp/fs-head-green.json"
forge_status pending > "$tmp/fs-head-pending.json"
run_forge "forgejo: red head under a red main is indeterminate" indeterminate 3 "$tmp/pr-open.json" "$tmp/fs-head-red.json" "$tmp/fs-base-red.json"
jq -e '.reason == "base-gate-red" and .venue == "forgejo"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: forgejo base-gate-red must be named" >&2; exit 1; }
run_forge "forgejo: red head under a green main closes" close-ok 0 "$tmp/pr-open.json" "$tmp/fs-head-red.json" "$tmp/fs-base-green.json"
run_forge "forgejo: green unmerged head refuses" refuse 1 "$tmp/pr-open.json" "$tmp/fs-head-green.json" "$tmp/fs-base-green.json"
run_forge "forgejo: pending head is indeterminate" indeterminate 3 "$tmp/pr-open.json" "$tmp/fs-head-pending.json" "$tmp/fs-base-green.json"
pr_row closed true "$STRAY" > "$tmp/pr-merged.json"
run_forge "forgejo: a merged PR is already terminal" close-ok 0 "$tmp/pr-merged.json" "$tmp/fs-head-red.json" "$tmp/fs-base-red.json"
pr_row open false "$LANDED" > "$tmp/pr-landed.json"
run_forge "forgejo: head already in main closes" close-ok 0 "$tmp/pr-landed.json" "$tmp/fs-head-red.json" "$tmp/fs-base-red.json"
# The event suffix must not matter: a base read as `(push)` matches the same stem.
jq -e '.head_in_base == "true"' "$tmp/out.json" >/dev/null || { echo "FAIL: landed forgejo head must read head_in_base=true" >&2; exit 1; }

# ── 10b. forgejo default ancestry repo: the portal cache, fetched by PR ref ──
# papercut-pr-reaper-forgejo-ancestry-object-missing: the guard read the
# LastGit mirror first (origin = GitHub, no PR heads), so every Forgejo PR was
# `ancestry-object-missing`. With no --git-dir, forgejo must use
# ~/.cache/edgevector-git/<repo>.git and fetch refs/pull/<n>/head from origin.
fhome="$tmp/home"
forge="$tmp/forge.git"
"$git_bin" init --quiet --bare "$forge"
"$git_bin" -C "$repo" push --quiet "$forge" "$MAIN:refs/heads/main" "$STRAY:refs/pull/7/head"
mkdir -p "$fhome/.lastgit/mirrors" "$fhome/.cache/edgevector-git"
"$git_bin" init --quiet --bare "$fhome/.lastgit/mirrors/brain"   # relic: no objects
"$git_bin" init --quiet --bare "$fhome/.cache/edgevector-git/brain.git"
"$git_bin" -C "$fhome/.cache/edgevector-git/brain.git" remote add origin "$forge"
rc=0
HOME="$fhome" "$guard" --venue forgejo --repo brain --pr 7 \
  --pr-json "$tmp/pr-open.json" --head-status-json "$tmp/fs-head-green.json" \
  --base-status-json "$tmp/fs-base-green.json" --base-oid "$MAIN" --json \
  >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
if [ "$rc" != 1 ] || ! jq -e '.verdict == "refuse" and .head_in_base == "false"' "$tmp/out.json" >/dev/null; then
  echo "FAIL forgejo default ancestry repo: want refuse/1 with head_in_base=false, got rc=$rc" >&2
  cat "$tmp/out.json" "$tmp/out.err" >&2 || true
  exit 1
fi
echo "ok   forgejo: default ancestry repo is the portal cache; PR head fetched by refs/pull"
rc=0
HOME="$fhome" "$guard" --venue forgejo --repo EdgeVector/brain --pr 7 \
  --pr-json "$tmp/pr-open.json" --head-status-json "$tmp/fs-head-green.json" \
  --base-status-json "$tmp/fs-base-green.json" --base-oid "$MAIN" --json \
  >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
jq -e '.repo == "brain" and .verdict == "refuse"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL owner/name --repo must normalize to the bare name (rc=$rc)" >&2; cat "$tmp/out.json" "$tmp/out.err" >&2; exit 1; }
echo "ok   forgejo: --repo EdgeVector/<name> is accepted"

# The ancestry fetch must go through the forge-token wrapper: Forgejo repos are
# private and an unattended shell cannot unlock the login keychain.
"$git_bin" init --quiet --bare "$fhome/.cache/edgevector-git/brain2.git"
"$git_bin" -C "$fhome/.cache/edgevector-git/brain2.git" remote add origin "$forge"
cat >"$tmp/fake-forge-git" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_FORGE_GIT_LOG"
exec git "$@"
SH
chmod +x "$tmp/fake-forge-git"
rc=0
HOME="$fhome" LAST_STACK_FORGE_GIT="$tmp/fake-forge-git" FAKE_FORGE_GIT_LOG="$tmp/forge-git.log" \
  "$guard" --venue forgejo --repo brain2 --pr 7 \
  --pr-json "$tmp/pr-open.json" --head-status-json "$tmp/fs-head-green.json" \
  --base-status-json "$tmp/fs-base-green.json" --base-oid "$MAIN" --json \
  >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
grep -q 'fetch --quiet --no-write-fetch-head origin refs/pull/7/head' "$tmp/forge-git.log" 2>/dev/null \
  || { echo "FAIL forgejo ancestry fetch must use the forge-token wrapper" >&2; cat "$tmp/out.json" >&2; exit 1; }
jq -e '.verdict == "refuse"' "$tmp/out.json" >/dev/null || { echo "FAIL wrapper fetch verdict (rc=$rc)" >&2; cat "$tmp/out.json" >&2; exit 1; }
echo "ok   forgejo: ancestry fetch goes through last-stack-forge-git"

# ── 10c. GitHub PRs go through the same ladder (LastGit retired, 2026-09-30) ──
# The PR row, the ci-required check run of the head and base, and the compare
# status come from `gh api`; every input can be a file.
gh_pr_row() { # gh_pr_row <state> <merged> <head>
  cat <<JSON
{"number":7,"state":"$1","merged":$2,"merged_at":null,"head":{"ref":"x","sha":"$3"},"base":{"ref":"main","sha":"$MAIN"}}
JSON
}
gh_checks() { # gh_checks <status> <conclusion>
  cat <<JSON
{"total_count":2,"check_runs":[
  {"name":"ci-required","status":"$1","conclusion":$2,"started_at":"2026-09-30T10:00:00Z"},
  {"name":"publish","status":"queued","conclusion":null,"started_at":"2026-09-30T10:00:01Z"}]}
JSON
}
gh_compare() { echo "{\"status\":\"$1\"}"; }
run_gh() { # run_gh <label> <verdict> <exit> <pr> <head-checks> <base-checks> <compare> [extra...]
  local label="$1" want_verdict="$2" want_exit="$3" prj="$4" hc="$5" bc="$6" cmp="$7" rc=0
  shift 7
  "$guard" --venue github --repo brain --pr 7 \
    --pr-json "$prj" --head-check-json "$hc" --base-check-json "$bc" --compare-json "$cmp" \
    --base-oid "$MAIN" --json "$@" >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
  local got
  got="$(jq -r '.verdict' "$tmp/out.json" 2>/dev/null || echo PARSE-FAIL)"
  if [ "$got" != "$want_verdict" ] || [ "$rc" != "$want_exit" ]; then
    echo "FAIL $label: want verdict=$want_verdict exit=$want_exit, got verdict=$got exit=$rc" >&2
    cat "$tmp/out.json" "$tmp/out.err" >&2 || true
    exit 1
  fi
  echo "ok   $label ($got, exit $rc)"
}
gh_pr_row open false "$STRAY" > "$tmp/gpr-open.json"
gh_checks completed '"failure"' > "$tmp/gc-head-red.json"
gh_checks completed '"failure"' > "$tmp/gc-base-red.json"
gh_checks completed '"success"' > "$tmp/gc-base-green.json"
gh_checks completed '"success"' > "$tmp/gc-head-green.json"
gh_checks in_progress null > "$tmp/gc-head-pending.json"
gh_checks completed '"cancelled"' > "$tmp/gc-head-cancelled.json"
gh_compare ahead > "$tmp/gcmp-ahead.json"
gh_compare diverged > "$tmp/gcmp-diverged.json"
gh_compare behind > "$tmp/gcmp-behind.json"
gh_compare identical > "$tmp/gcmp-identical.json"
run_gh "github: red head under a red main is indeterminate" indeterminate 3 "$tmp/gpr-open.json" "$tmp/gc-head-red.json" "$tmp/gc-base-red.json" "$tmp/gcmp-ahead.json"
jq -e '.reason == "base-gate-red" and .venue == "github"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: github base-gate-red must be named" >&2; exit 1; }
run_gh "github: red head under a green main closes" close-ok 0 "$tmp/gpr-open.json" "$tmp/gc-head-red.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
run_gh "github: cancelled head closes" close-ok 0 "$tmp/gpr-open.json" "$tmp/gc-head-cancelled.json" "$tmp/gc-base-green.json" "$tmp/gcmp-diverged.json"
run_gh "github: green unmerged head refuses" refuse 1 "$tmp/gpr-open.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
run_gh "github: pending head is indeterminate" indeterminate 3 "$tmp/gpr-open.json" "$tmp/gc-head-pending.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
jq -e '.reason == "required-check-running"' "$tmp/out.json" >/dev/null || { echo "FAIL: github pending must read required-check-running" >&2; exit 1; }
gh_pr_row closed true "$STRAY" > "$tmp/gpr-merged.json"
run_gh "github: a merged PR is already terminal" close-ok 0 "$tmp/gpr-merged.json" "$tmp/gc-head-red.json" "$tmp/gc-base-red.json" "$tmp/gcmp-ahead.json"
gh_pr_row closed false "$STRAY" > "$tmp/gpr-closed.json"
run_gh "github: a closed PR is already terminal" close-ok 0 "$tmp/gpr-closed.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
run_gh "github: head already in main (compare behind) closes" close-ok 0 "$tmp/gpr-open.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-behind.json"
jq -e '.head_in_base == "true"' "$tmp/out.json" >/dev/null || { echo "FAIL: compare behind must read head_in_base=true" >&2; exit 1; }
run_gh "github: identical compare closes" close-ok 0 "$tmp/gpr-open.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-identical.json"
echo '{"message":"Not Found"}' > "$tmp/gcmp-bad.json"
run_gh "github: an unreadable compare is indeterminate" indeterminate 3 "$tmp/gpr-open.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-bad.json"
jq -e '.reason == "ancestry-unreadable"' "$tmp/out.json" >/dev/null || { echo "FAIL: github unreadable compare must name ancestry-unreadable" >&2; exit 1; }
echo '{"check_runs":[]}' > "$tmp/gc-head-none.json"
run_gh "github: no ci-required check run is indeterminate" indeterminate 3 "$tmp/gpr-open.json" "$tmp/gc-head-none.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
# With --git-dir the guard uses local ancestry (objects only), same verdicts.
run_gh "github: --git-dir ancestry, green unmerged refuses" refuse 1 "$tmp/gpr-open.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-bad.json" --git-dir "$repo" --no-fetch

# The guard reads every input through `gh api` when no fixture file is given.
mkdir -p "$tmp/ghstub"
cat >"$tmp/ghstub/gh" <<SH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 9
case "\$2" in
  repos/EdgeVector/brain/pulls/7) cat "$tmp/gpr-open.json" ;;
  repos/EdgeVector/brain/branches/main) echo '{"commit":{"sha":"$MAIN"}}' ;;
  repos/EdgeVector/brain/commits/$STRAY/check-runs*) cat "$tmp/gc-head-green.json" ;;
  repos/EdgeVector/brain/compare/*) cat "$tmp/gcmp-ahead.json" ;;
  *) echo "unexpected gh api \$2" >&2; exit 8 ;;
esac
SH
chmod +x "$tmp/ghstub/gh"
rc=0
LAST_STACK_GH_BIN="$tmp/ghstub/gh" "$guard" --venue github --repo brain --pr 7 --json >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
if [ "$rc" != 1 ] || ! jq -e '.venue == "github" and .reason == "green-unmerged-auto-merge"' "$tmp/out.json" >/dev/null; then
  echo "FAIL: gh-stub live read must refuse the green unmerged PR (rc=$rc)" >&2; cat "$tmp/out.json" "$tmp/out.err" >&2; exit 1
fi
echo "ok   github: every read goes through gh api"

# --venue auto and the --pr default route through last-stack-pr-venue.
cat >"$tmp/pr-venue-github" <<'SH'
#!/usr/bin/env bash
echo github
SH
cat >"$tmp/pr-venue-forgejo" <<'SH'
#!/usr/bin/env bash
echo forgejo
SH
cat >"$tmp/pr-venue-lastgit" <<'SH'
#!/usr/bin/env bash
echo lastgit
SH
chmod +x "$tmp/pr-venue-github" "$tmp/pr-venue-forgejo" "$tmp/pr-venue-lastgit"
rc=0
LAST_STACK_PR_VENUE_BIN="$tmp/pr-venue-github" "$guard" --repo brain --pr 7 \
  --pr-json "$tmp/gpr-open.json" --head-check-json "$tmp/gc-head-green.json" --base-check-json "$tmp/gc-base-green.json" \
  --compare-json "$tmp/gcmp-ahead.json" --base-oid "$MAIN" --json >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
if [ "$rc" != 1 ] || ! jq -e '.venue == "github" and .verdict == "refuse"' "$tmp/out.json" >/dev/null; then
  echo "FAIL: --pr with no --venue must route to github (rc=$rc)" >&2; cat "$tmp/out.json" "$tmp/out.err" >&2; exit 1
fi
rc=0
LAST_STACK_PR_VENUE_BIN="$tmp/pr-venue-forgejo" "$guard" --venue auto --repo brain --pr 7 \
  --pr-json "$tmp/pr-open.json" --head-status-json "$tmp/fs-head-green.json" --base-status-json "$tmp/fs-base-green.json" \
  --base-oid "$MAIN" --git-dir "$repo" --no-fetch --json >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
if [ "$rc" != 1 ] || ! jq -e '.venue == "forgejo" and .verdict == "refuse"' "$tmp/out.json" >/dev/null; then
  echo "FAIL: --venue auto must route to forgejo when the venue helper says forgejo (rc=$rc)" >&2; cat "$tmp/out.json" "$tmp/out.err" >&2; exit 1
fi
rc=0
LAST_STACK_PR_VENUE_BIN="$tmp/pr-venue-lastgit" "$guard" --venue auto --repo brain --pr 7 >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: a lastgit answer with --pr must be a usage error (rc=$rc)" >&2; exit 1; }
# LastGit is retired: --cr and --venue lastgit are usage errors, never a lastgit call.
rc=0
"$guard" --repo last-stack --cr cr-test-0001 --json >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: --cr must be a usage error (rc=$rc)" >&2; exit 1; }
rc=0
"$guard" --venue lastgit --repo last-stack --pr 7 --json >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: --venue lastgit must be a usage error (rc=$rc)" >&2; exit 1; }
# An unreadable GitHub PR row fails closed.
echo 'not json' > "$tmp/gpr-bad.json"
run_gh "github: an unreadable PR row fails closed" indeterminate 3 "$tmp/gpr-bad.json" "$tmp/gc-head-green.json" "$tmp/gc-base-green.json" "$tmp/gcmp-ahead.json"
echo "ok   github: --venue auto and the --pr default route through last-stack-pr-venue"

# ── 11. the prompt must actually run the guard ─────────────────────────────
# A helper nothing calls is not a guard. This is the half that failed before:
# routines/pr-reaper.md STEP 2 had a two-branch ladder and no call site.
prompt="$ROOT/routines/pr-reaper.md"
grep -q 'bin/last-stack-pr-reaper-close-guard' "$prompt" \
  || { echo "FAIL: routines/pr-reaper.md must invoke the close guard" >&2; exit 1; }
for token in 'close-refused-green-unmerged' 'close-indeterminate' 'close-deferred-base-gate-red' '--venue auto' '--venue github' '--venue forgejo' 'gh -R <owner>/<repo> pr close'; do
  grep -q -- "$token" "$prompt" \
    || { echo "FAIL: pr-reaper.md must carry $token so the refusal stays measurable" >&2; exit 1; }
done
# The call site must precede the close verbs it gates, or it gates nothing.
guard_line="$(grep -n 'bin/last-stack-pr-reaper-close-guard' "$prompt" | head -1 | cut -d: -f1)"
close_line="$(grep -n 'pr close' "$prompt" | tail -1 | cut -d: -f1)"
if [ -z "$guard_line" ] || [ -z "$close_line" ] || [ "$guard_line" -gt "$close_line" ]; then
  echo "FAIL: the guard must be introduced before the last close verb (guard=$guard_line close=$close_line)" >&2
  exit 1
fi
echo "ok   pr-reaper.md wires the guard ahead of its close verbs"

echo "PASS last-stack-pr-reaper-close-guard"
