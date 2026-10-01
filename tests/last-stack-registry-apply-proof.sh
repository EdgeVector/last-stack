#!/usr/bin/env bash
# bin/last-stack-registry-apply-proof: the Mac half of the CI registry proof.
# Hermetic: a fake `gh` (runs, artifacts, tap PRs), a fake `lastdb` (sign and
# verify only), a local bare repo for the tap, and the REAL publish-next and
# proof-plan manifest tools. No network, no real key, no real tap.
#
#   1. GREEN run: rows are signed and pushed on a branch that names the run id,
#      one tap PR is opened with auto-merge armed
#   2. --dry-run: verifies and shows the rows, pushes nothing, opens nothing,
#      leaves the real tap checkout path untouched
#   3. attributed RED: rows for the passed apps only
#   4. refusals: shared RED, wrong repository, fork head, wrong branch, wrong
#      workflow, wrong event, run not completed, build mismatch (candidate set
#      vs proof), --expect-build mismatch, tampered bundle, old run, a stale
#      proof that would move a pin backwards, an open tap row PR (serial)
#   5. already applied: nothing to do
#   6. --latest skips a run that does not verify and takes the next one
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-registry-apply-proof"
PLAN="$ROOT/bin/last-stack-registry-proof-plan"
work="$(mktemp -d "${TMPDIR:-/tmp}/apply-proof.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$work/home"
mkdir -p "$HOME"
fx="$work/fx"; mkdir -p "$fx"
calls="$work/gh.calls"; : >"$calls"

REPO=EdgeVector/last-stack
TAP=EdgeVector/homebrew-lastdb
BUILD=0.23.3-2378-gbe41e547e
OID=be41e547e901f835fff7ad09bcc3a8f4df8265e0
HEAD_SHA=cafecafecafecafecafecafecafecafecafecafe
A1=1111111111111111111111111111111111111111
A2=2222222222222222222222222222222222222222
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- the tap: a bare repo with the scaffold -----------------------------------
src="$work/tap-src"
git init --quiet -b main "$src"
mkdir -p "$src/registry/proofs"
"$ROOT/bin/last-stack-registry-index" init --channel next --out "$src/registry/next.json" >/dev/null
git -C "$src" add registry
git -C "$src" -c user.name=t -c user.email=t@example.com commit --quiet -m scaffold
git clone --quiet --bare "$src" "$work/tap-live.git"
cp "$src/registry/next.json" "$fx/tap-next.json"
printf 'test-key\n' >"$work/signing.key"

# --- fake lastdb and fake gh -------------------------------------------------------
cat >"$work/lastdb" <<'LDEOF'
#!/usr/bin/env bash
[ "$1 $2" = "app index" ] || { echo "fake lastdb: $*" >&2; exit 2; }
case "$3" in
  sign)
    [ "${4:-}" = --help ] && exit 0
    idx=""; while [ "$#" -gt 0 ]; do [ "$1" = --index ] && idx="$2"; shift; done
    printf '{"alg":"ed25519"}\n' >"$idx.sig"; echo signed >>"$LASTDB_CALLS" ;;
  verify) exit 0 ;;
esac
LDEOF
chmod +x "$work/lastdb"
export LASTDB_CALLS="$work/lastdb.calls"

cat >"$work/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$calls"
fx="$fx"
case "\$1" in
  pr)
    case "\$2" in
      list) cat "\$fx/open-prs.json" ;;
      create) printf 'https://github.com/$TAP/pull/555\n' ;;
      merge|view) echo '{"state":"MERGED","mergeStateStatus":"CLEAN","autoMergeRequest":null}' ;;
    esac ;;
  api)
    case "\$2" in
      repos/$REPO/actions/runs/*/jobs*) id="\${2#repos/$REPO/actions/runs/}"; cat "\$fx/jobs-\${id%%/*}.json" ;;
      repos/$REPO/actions/runs/*) f="\$fx/run-\${2##*/}.json"; [ -f "\$f" ] && cat "\$f" || { echo "no such run" >&2; exit 1; } ;;
      repos/$REPO/actions/workflows/*) cat "\$fx/runs-list.json" ;;
      repos/$TAP/contents/registry/next.json) cat "\$fx/tap-next.json" ;;
      *) echo "fake gh api: \$*" >&2; exit 1 ;;
    esac ;;
  run)
    # gh run download <id> -R repo -n name -D dir
    id="\$3"; dir=""
    while [ "\$#" -gt 0 ]; do [ "\$1" = -D ] && dir="\$2"; shift; done
    [ -d "\$fx/bundle-\$id" ] || { echo "no artifact" >&2; exit 1; }
    mkdir -p "\$dir"; cp -R "\$fx/bundle-\$id/." "\$dir/" ;;
esac
GHEOF
chmod +x "$work/gh"
echo '[]' >"$fx/open-prs.json"

# --- fixtures ------------------------------------------------------------------------
# mkrun <id> <conclusion> <verdict> <attr text> [proof build] [set build]
mkrun() {
  local id="$1" conclusion="$2" verdict="$3" attr="$4" pbuild="${5:-$BUILD}" sbuild="${6:-$BUILD}"
  local b="$fx/bundle-$id"
  rm -rf "$b"; mkdir -p "$b"
  jq -n --arg b "$sbuild" --arg o "$OID" --arg a1 "$A1" --arg a2 "$A2" \
    '{created_at: "2026-10-01T00:00:00Z", lastdb: {build: $b, oid: $o, oid_source: "flag", bin: ""},
      apps: {alpha: {sha: $a1, app_version: "1.0.0", source: "https://github.com/EdgeVector/alpha.git", description: "a"},
             beta: {sha: $a2, app_version: "2.0.0", source: "https://github.com/EdgeVector/beta.git", description: "b"}}}' >"$b/candidate-set.json"
  jq -n --arg v "$verdict" --arg b "$pbuild" --arg o "$OID" --arg at "$NOW" \
    '{verdict: $v, pass: 30, sandbox: "/tmp/x", proved_at: $at, lastdb_build: $b, lastdb_oid: $o, fold_oid: $o,
      fails: (if $v == "GREEN" then [] else ["install-apps:beta:pinned"] end)}' >"$b/proof.json"
  printf '%b' "$attr" >"$b/attribution.txt"
  "$PLAN" manifest --bundle "$b" --run-id "$id" --run-attempt 1 --repository "$REPO" --sha "$HEAD_SHA" \
    --ref refs/heads/main --event schedule --run-url "https://github.com/$REPO/actions/runs/$id" \
    --moved alpha,beta --fingerprint fp >/dev/null
  mkrunmeta "$id" "$conclusion"
}
# mkrunmeta <id> <conclusion of the proof job> [jq filter to break something]
mkrunmeta() {
  local id="$1" conclusion="$2" breaker="${3:-.}"
  jq -n --arg id "$id" --arg c "$conclusion" --arg repo "$REPO" --arg sha "$HEAD_SHA" --arg at "$NOW" \
    '{id: ($id | tonumber), status: "completed", conclusion: $c, event: "schedule", head_branch: "main", head_sha: $sha,
      path: ".github/workflows/registry-proof.yml", created_at: $at, html_url: ("https://github.com/" + $repo + "/actions/runs/" + $id),
      repository: {full_name: $repo}, head_repository: {full_name: $repo}}' | jq "$breaker" >"$fx/run-$id.json"
  # the run-level conclusion is "failure" whenever the report job failed; the verdict is the proof job
  jq -n --arg c "$conclusion" '{jobs: [{name: "plan", conclusion: "success"}, {name: "proof", conclusion: $c}, {name: "report", conclusion: "failure"}]}' >"$fx/jobs-$id.json"
}

export GH_BIN="$work/gh" LASTDB_BIN="$work/lastdb" LASTDB_REGISTRY_SIGNING_KEY="$work/signing.key"
export LAST_STACK_REGISTRY_TAP_URL="$work/tap-live.git" LAST_STACK_REGISTRY_TAP_DIR="$work/tapdir"
export LAST_STACK_REGISTRY_KNOWN_APPS="alpha beta"
real_tap_dir="$HOME/.local/state/last-stack/registry-tap"
branches() { git --git-dir "$work/tap-live.git" for-each-ref --format='%(refname:short)' 'refs/heads/registry/*'; }
# run <expected exit> <args...>: runs the command, keeps stdout in $out and stderr in $err
run() {
  local want="$1"; shift
  set +e; "$BIN" "$@" >"$work/out" 2>"$work/err"; rc=$?; set -e
  out="$(cat "$work/out")"; err="$(cat "$work/err")"
  [ "$rc" = "$want" ] || fail "exit $rc, wanted $want for: $* | out: $out | err: $err"
}
no_publish() { [ -z "$(branches)" ] || fail "a row branch was pushed: $(branches)"; if grep -q '^pr create' "$calls"; then fail "a PR was opened"; fi; }

# --- 2. dry-run first: nothing may be written ---------------------------------------
mkrun 1001 success GREEN 'verdict=GREEN\n'
run 0 --run-id 1001 --dry-run
grep -q 'APPLY_PROOF status=dry-run run=1001' <<<"$out" || fail "dry-run status: $out"
grep -q "alpha.*$A1.*$BUILD" <<<"$out" || fail "dry-run rows (app, sha, build): $out"
grep -q "beta.*$A2.*$BUILD" <<<"$out" || fail "dry-run rows (beta): $out"
no_publish
[ ! -e "$work/tapdir" ] || fail "dry-run wrote the tap checkout dir"
[ ! -e "$real_tap_dir" ] || fail "dry-run wrote the default tap checkout dir"
[ ! -s "$LASTDB_CALLS" ] || [ "$(grep -c signed "$LASTDB_CALLS")" -le 1 ] || fail "dry-run signed more than once"
if grep -q '^pr merge' "$calls"; then fail "dry-run armed auto-merge"; fi

# --- 1. GREEN apply ------------------------------------------------------------------------
: >"$calls"
run 0 --run-id 1001
grep -q 'APPLY_PROOF status=pr run=1001' <<<"$out" || fail "apply status: $out"
grep -q "REGISTRY_NEXT status=pr build=$BUILD apps=2 proof_run=ci-smoke-1001-$BUILD pr=$TAP/555" <<<"$out" || fail "publish-next line: $out"
grep -Eq "^pr create --repo $TAP --base main --head registry/next-0\\.23\\.3-2378-gbe41e547e-[0-9TZ]+-1001-[0-9]+ " "$calls" || fail "branch lacks the run id: $(grep '^pr create' "$calls")"
grep -q "^pr merge 555 --repo $TAP --squash --auto --delete-branch" "$calls" || fail "auto-merge not armed"
[ "$(branches | wc -l | tr -d ' ')" = 1 ] || fail "one row branch expected: $(branches)"
b="$(branches)"
git --git-dir "$work/tap-live.git" show "$b:registry/proofs/ci-smoke-1001-$BUILD.json" >"$work/proofrec.json" || fail "proof record missing on the branch"
[ "$(jq -r '.apps_proved' "$work/proofrec.json")" = null ] || fail "GREEN proof must not be partial"
git --git-dir "$work/tap-live.git" show "$b:registry/next.json" | jq -e --arg a "$A1" --arg b "$BUILD" \
  '.apps[] | select(.app_id == "alpha") | .compat[] | select(.sha == $a and .lastdb_version == $b and .proof_run == "ci-smoke-1001-" + $b)' >/dev/null || fail "alpha row missing"
grep -q signed "$LASTDB_CALLS" || fail "the local lastdb did not sign"
git --git-dir "$work/tap-live.git" show "$b:registry/next.json.sig" >/dev/null || fail "no signature on the branch"
# the tap checkout the publish used is OURS (env), never a CI path
[ -d "$work/tapdir/.git" ] || fail "tap checkout not used"

# --- 5. already applied ---------------------------------------------------------------------
reset_tap() { git --git-dir "$work/tap-live.git" for-each-ref --format='%(refname)' 'refs/heads/registry/*' | while read -r r; do git --git-dir "$work/tap-live.git" update-ref -d "$r"; done; rm -rf "$work/tapdir"; : >"$calls"; }
reset_tap
jq -n --arg b "$BUILD" --arg a1 "$A1" --arg a2 "$A2" --arg at "$NOW" '{index_version: 1, channel: "next", apps: [
  {app_id: "alpha", source: "s", compat: [{sha: $a1, lastdb_version: $b, proved_at: $at, proof_run: "p"}]},
  {app_id: "beta", source: "s", compat: [{sha: $a2, lastdb_version: $b, proved_at: $at, proof_run: "p"}]}]}' >"$fx/tap-next.json"
run 0 --run-id 1001
grep -q 'APPLY_PROOF status=already-applied' <<<"$out" || fail "already applied: $out"
no_publish

# --- 4j. stale: the tap holds a NEWER row for an app and build with another sha ------------------
jq -n --arg b "$BUILD" --arg a1 "$A1" --arg at "2999-01-01T00:00:00Z" '{index_version: 1, channel: "next", apps: [
  {app_id: "alpha", source: "s", compat: [{sha: "9999999999999999999999999999999999999999", lastdb_version: $b, proved_at: $at, proof_run: "p"}]}]}' >"$fx/tap-next.json"
run 3 --run-id 1001
grep -q 'reason=stale-proof' <<<"$out" || fail "stale: $out"
no_publish
cp "$src/registry/next.json" "$fx/tap-next.json"

# --- 3. attributed RED: rows for the passed apps only --------------------------------------------
reset_tap
mkrun 1002 failure RED 'verdict=RED\nshared_fail=0\npassed_apps=alpha\nfailed_apps=beta\n'
run 0 --run-id 1002
grep -q "apps=1 proof_run=ci-smoke-1002-$BUILD" <<<"$out" || fail "partial apply: $out"
b="$(branches)"
git --git-dir "$work/tap-live.git" show "$b:registry/next.json" | jq -e '[.apps[].app_id] == ["alpha"]' >/dev/null || fail "only alpha may get a row"
git --git-dir "$work/tap-live.git" show "$b:registry/proofs/ci-smoke-1002-$BUILD.json" | jq -e '.partial == true' >/dev/null || fail "partial record"
if grep -q "^  beta" <<<"$out"; then fail "the failed app was listed as a row"; fi

# --- 4. refusals: each leaves the tap and gh untouched -----------------------------------------------
refuse() {  # refuse <what> <args...>
  local what="$1"; shift
  reset_tap
  run 3 "$@"
  grep -q 'APPLY_PROOF status=refused' <<<"$out" || fail "$what: no refused line: $out | $err"
  no_publish
}
mkrun 2001 failure RED 'verdict=RED\nshared_fail=1\npassed_apps=alpha beta\nfailed_apps=\n'
refuse "shared RED" --run-id 2001
grep -q 'shared fail' <<<"$err" || fail "shared RED reason: $err"

mkrun 2002 success GREEN 'verdict=GREEN\n'
mkrunmeta 2002 success '.repository.full_name = "someone/last-stack"'
refuse "wrong repository" --run-id 2002; grep -q 'repository is someone/last-stack' <<<"$err" || fail "repo reason: $err"

mkrun 2003 success GREEN 'verdict=GREEN\n'
mkrunmeta 2003 success '.head_repository.full_name = "fork/last-stack"'
refuse "fork head" --run-id 2003; grep -q 'fork' <<<"$err" || fail "fork reason: $err"

mkrun 2004 success GREEN 'verdict=GREEN\n'
mkrunmeta 2004 success '.head_branch = "kanban/evil"'
refuse "wrong branch" --run-id 2004; grep -q 'branch is kanban/evil' <<<"$err" || fail "branch reason: $err"

mkrun 2005 success GREEN 'verdict=GREEN\n'
mkrunmeta 2005 success '.path = ".github/workflows/other.yml"'
refuse "wrong workflow" --run-id 2005; grep -q 'workflow is' <<<"$err" || fail "workflow reason: $err"

mkrun 2006 success GREEN 'verdict=GREEN\n'
mkrunmeta 2006 success '.event = "pull_request"'
refuse "wrong event" --run-id 2006; grep -q 'event is pull_request' <<<"$err" || fail "event reason: $err"

mkrun 2007 success GREEN 'verdict=GREEN\n'
mkrunmeta 2007 success '.status = "in_progress"'
refuse "not completed" --run-id 2007; grep -q 'not completed' <<<"$err" || fail "status reason: $err"

# A bundle whose candidate set names another build than the proof, with every digest
# fixed up so only the build cross-check can catch it (the manifest tool refuses it earlier).
mkrun 2008 success GREEN 'verdict=GREEN\n'
jq '.lastdb.build = "0.23.3-1-gdeadbeef0"' "$fx/bundle-2008/candidate-set.json" >"$work/t.json" && mv "$work/t.json" "$fx/bundle-2008/candidate-set.json"
jq --arg d "$(shasum -a 256 "$fx/bundle-2008/candidate-set.json" | awk '{print $1}')" '.files["candidate-set.json"] = $d' "$fx/bundle-2008/apply.json" >"$work/t.json" && mv "$work/t.json" "$fx/bundle-2008/apply.json"
refuse "build mismatch (candidate set vs proof)" --run-id 2008; grep -q 'differs' <<<"$err" || fail "mismatch reason: $err"

mkrun 2009 success GREEN 'verdict=GREEN\n'
refuse "--expect-build mismatch" --run-id 2009 --expect-build 0.23.3-9-gabcdef012; grep -q 'not the expected' <<<"$err" || fail "expect reason: $err"

mkrun 2010 success GREEN 'verdict=GREEN\n'
jq '.pass = 31' "$fx/bundle-2010/proof.json" >"$work/t.json" && mv "$work/t.json" "$fx/bundle-2010/proof.json"
refuse "tampered bundle" --run-id 2010; grep -q 'digest' <<<"$err" || fail "tamper reason: $err"

mkrun 2011 success GREEN 'verdict=GREEN\n'
mkrunmeta 2011 success '.created_at = "2020-01-01T00:00:00Z"'
refuse "old run" --run-id 2011; grep -q 'older than' <<<"$err" || fail "age reason: $err"

mkrun 2012 success GREEN 'verdict=GREEN\n'
mkrunmeta 2012 failure
refuse "GREEN verdict on a failed proof job" --run-id 2012; grep -q 'proof job concluded failure' <<<"$err" || fail "conclusion reason: $err"

# a planned run whose plan said no-op has no proof job: nothing to apply
mkrun 2015 success GREEN 'verdict=GREEN\n'
jq -n '{jobs: [{name: "plan", conclusion: "success"}, {name: "proof", conclusion: "skipped"}]}' >"$fx/jobs-2015.json"
refuse "skipped proof job" --run-id 2015; grep -q 'proof job concluded skipped' <<<"$err" || fail "skipped reason: $err"

mkrun 2013 success GREEN 'verdict=GREEN\n'
rm -rf "$fx/bundle-2013"
refuse "no artifact" --run-id 2013

# serial: an open tap row PR refuses before any download
reset_tap
mkrun 2014 success GREEN 'verdict=GREEN\n'
echo '[{"number": 500, "headRefName": "registry/next-0.23.3-1-gabc-1-1", "url": "u"}]' >"$fx/open-prs.json"
run 3 --run-id 2014
grep -q 'reason=open-row-pr' <<<"$out" || fail "serial refusal: $out"
no_publish
if grep -q '^run download' "$calls"; then fail "the serial refusal must come before any download"; fi
# an unrelated open PR does not block
echo '[{"number": 501, "headRefName": "someone/readme", "url": "u"}]' >"$fx/open-prs.json"
run 0 --run-id 2014 --dry-run
echo '[]' >"$fx/open-prs.json"

# --- 6. --latest skips a run that does not verify and applies the next one ---------------------------
reset_tap
mkrun 3001 success GREEN 'verdict=GREEN\n'
mkrun 3002 failure RED 'verdict=RED\nshared_fail=1\npassed_apps=\nfailed_apps=\n'
jq -n '{workflow_runs: [{id: 3002, conclusion: "failure"}, {id: 3001, conclusion: "success"}, {id: 3000, conclusion: "cancelled"}]}' >"$fx/runs-list.json"
run 0 --latest
grep -q 'APPLY_PROOF status=pr run=3001' <<<"$out" || fail "--latest: $out"
grep -q 'skip: .*3002' <<<"$err" || fail "--latest did not report the skipped run: $err"
grep -q 'registry/next-.*-3001-' "$calls" || fail "--latest branch"

echo "ok last-stack-registry-apply-proof"
