#!/usr/bin/env bash
# bin/last-stack-registry-proof-plan manifest: the proof bundle carries
# everything the Mac apply command needs (verdict JSON, candidate set with
# shas, lastdb build and oid, run id and URL, per-app attribution, proof record
# name), and holds no binary. Fixture only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLAN="$ROOT/bin/last-stack-registry-proof-plan"
work="$(mktemp -d "${TMPDIR:-/tmp}/proof-manifest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

BUILD=0.23.3-2378-gbe41e547e
OID=be41e547e901f835fff7ad09bcc3a8f4df8265e0
A1=1111111111111111111111111111111111111111
A2=2222222222222222222222222222222222222222
URL=https://github.com/EdgeVector/last-stack/actions/runs/36800000001

mkbundle() {
  local dir="$1" verdict="$2" proofbuild="$3" attr="$4"
  mkdir -p "$dir"
  jq -n --arg b "$BUILD" --arg o "$OID" --arg a1 "$A1" --arg a2 "$A2" \
    '{created_at: "2026-10-01T00:00:00Z", lastdb: {build: $b, oid: $o, oid_source: "flag", bin: ""},
      apps: {alpha: {sha: $a1}, beta: {sha: $a2}}}' >"$dir/candidate-set.json"
  jq -n --arg v "$verdict" --arg b "$proofbuild" --arg o "$OID" \
    '{verdict: $v, fails: (if $v == "GREEN" then [] else ["install-apps:beta:pinned"] end), lastdb_build: $b, lastdb_oid: $o, fold_oid: $o}' >"$dir/proof.json"
  printf '%b' "$attr" >"$dir/attribution.txt"
}

run() {
  "$PLAN" manifest --bundle "$1" --run-id 36800000001 --run-attempt 1 --repository EdgeVector/last-stack \
    --sha cafe --ref refs/heads/main --event schedule --run-url "$URL" --moved alpha,beta --fingerprint abc123
}

# 1. GREEN
mkbundle "$work/green" GREEN "$BUILD" 'verdict=GREEN\n'
run "$work/green" >/dev/null || fail "green manifest"
m="$work/green/apply.json"
[ "$(jq -r .schema "$m")" = registry-proof-bundle/1 ] || fail "schema"
[ "$(jq -r .run_id "$m")" = 36800000001 ] || fail "run_id"
[ "$(jq -r .run_url "$m")" = "$URL" ] || fail "run_url"
[ "$(jq -r .repository "$m")" = EdgeVector/last-stack ] || fail "repository"
[ "$(jq -r .workflow_path "$m")" = .github/workflows/registry-proof.yml ] || fail "workflow_path"
[ "$(jq -r .lastdb.build "$m")" = "$BUILD" ] || fail "build"
[ "$(jq -r .lastdb.oid "$m")" = "$OID" ] || fail "oid"
[ "$(jq -r .verdict "$m")" = GREEN ] || fail "verdict"
[ "$(jq -r .shared_fail "$m")" = false ] || fail "GREEN is not a shared fail"
[ "$(jq -r .apps.beta "$m")" = "$A2" ] || fail "apps sha"
[ "$(jq -r .proof_run "$m")" = "ci-smoke-36800000001-$BUILD" ] || fail "proof_run: $(jq -r .proof_run "$m")"
[ "$(jq -r '.moved | join(",")' "$m")" = alpha,beta ] || fail "moved"
[ "$(jq -r .files.\"proof.json\" "$m")" = "$(shasum -a 256 "$work/green/proof.json" | awk '{print $1}')" ] || fail "proof digest"

# 2. attributed RED: per-app, passed and failed apps named
mkbundle "$work/red" RED "$BUILD" 'verdict=RED\nshared_fail=0\npassed_apps=alpha\nfailed_apps=beta\n'
run "$work/red" >/dev/null || fail "red manifest"
m="$work/red/apply.json"
[ "$(jq -r .shared_fail "$m")" = false ] || fail "attributed RED is not shared"
[ "$(jq -r '.passed_apps | join(",")' "$m")" = alpha ] || fail "passed"
[ "$(jq -r '.failed_apps | join(",")' "$m")" = beta ] || fail "failed"

# 3. shared RED, and a RED with no attribution file, both read as shared
mkbundle "$work/shared" RED "$BUILD" 'verdict=RED\nshared_fail=1\npassed_apps=alpha beta\nfailed_apps=\n'
run "$work/shared" >/dev/null || fail "shared manifest"
[ "$(jq -r .shared_fail "$work/shared/apply.json")" = true ] || fail "shared"
mkbundle "$work/noattr" RED "$BUILD" ''
rm -f "$work/noattr/attribution.txt"
run "$work/noattr" >/dev/null || fail "noattr manifest"
[ "$(jq -r .shared_fail "$work/noattr/apply.json")" = true ] || fail "missing attribution must read as shared"

# 4. a proof that names another build than the candidate set is refused
mkbundle "$work/mismatch" GREEN 0.23.3-1-gdeadbeef0 'verdict=GREEN\n'
if run "$work/mismatch" >/dev/null 2>"$work/err"; then fail "build mismatch must be refused"; fi
grep -q 'candidate set is' "$work/err" || fail "mismatch reason: $(cat "$work/err")"

# 5. the manifest names no binary and no secret-looking field
if jq -e '[paths | map(tostring) | join(".")] | any(test("token|secret|key|binary"; "i"))' "$work/green/apply.json" >/dev/null; then
  fail "manifest carries a secret-looking or binary field"
fi

echo "ok last-stack-registry-proof-manifest"
