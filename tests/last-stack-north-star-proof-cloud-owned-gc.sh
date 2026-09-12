#!/usr/bin/env bash
# Hermetic rejection tests. A fake verifier must NEVER establish release truth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HARNESS="$ROOT/harness/north-star/cloud-owned-gc/run.sh"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
SLUG=north-star-lastdb-cloud-owned-gc
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloud-owned-gc-rejection-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/caller" "$WORK/tmp" "$WORK/reports" "$WORK/markers"

# Do not load a user's Git hooks, filters, credentials, or commit identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES BASH_ENV
unset CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE CLOUD_OWNED_GC_PROOF_NONCE FOLD_REPO

fail() { printf 'cloud-owned-gc fixture: %s\n' "$*" >&2; exit 1; }
git_fixture() { git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid "$@"; }
FOLD="$WORK/fold source"
mkdir -p "$FOLD/scripts"
git_fixture -C "$FOLD" init -q
printf 'fixture\n' >"$FOLD/control"
cat >"$FOLD/scripts/prove-cloud-owned-gc" <<'VERIFIER'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = --require-full-release-proof ] || exit 61
[ "${NORTH_STAR_PROOF_MODE:-}" = live ] || exit 62
[ "$(pwd -P)" = "$EXPECTED_FOLD" ] || exit 63
[ "${CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE:-}" = /dev/null ] || exit 64
[ -z "${CLOUD_OWNED_GC_PROOF_NONCE:-}" ] || exit 65
IFS= read -r first <"$EXPECTED_REPORT"
[ "$first" = FAIL ] || exit 66
printf 'executed\n' >"$CHILD_MARKER"
case "${FAKE_OUTPUT:-empty}" in
  empty) ;;
  pass) printf 'PASS\n' ;;
  malformed) printf '{not-json\n' ;;
  json) printf '{"verdict":"PASS","scope":"full-release","complete":true}\n' ;;
  private) printf 'PASS\n- Proof scope: private-dev\n' ;;
  incomplete) printf 'PASS\n- Proof scope: full-release\n- Fresh cloud restore: PASS\n' ;;
  checklist)
    # The old consumer accepted this invented checklist as a real full PASS.
    printf 'PASS\n- Harness nonce: self-declared\n- Proof scope: full-release\n'
    printf '%s\n' '- Source oid: 0123456789abcdef0123456789abcdef01234567'
    printf '%s\n' '- Daemon sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    printf '%s\n' '- Fixture: isolated copy' '- Cold boots: 2'
    printf '%s\n' '- Payload classes complete: backup-chunks manifests mutation-logs owned-file-versions declared-caches'
    for field in 'Physical absence before boot' 'Retained controls' 'Fresh cloud restore' 'Concurrent publication' 'Source device disconnected before completion' 'Exact object bytes reconciled'; do
      printf -- '- %s: PASS\n' "$field"
    done
    ;;
  secret)
    printf '%s\n' 'SYNTHETIC_CHILD_SECRET_DO_NOT_PERSIST'
    printf '%s\n' 'SYNTHETIC_CHILD_SECRET_DO_NOT_PERSIST' >&2
    printf '%s\n' 'SYNTHETIC_CHILD_SECRET_DO_NOT_PERSIST' >"$CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE"
    ;;
  terminate) kill -TERM "$PPID" ;;
  kill) kill -KILL "$PPID" ;;
  poison-report) printf 'PASS\n' >"$EXPECTED_REPORT" ;;
  *) exit 67 ;;
esac
exit "${FAKE_RC:-0}"
VERIFIER
chmod +x "$FOLD/scripts/prove-cloud-owned-gc"
git_fixture -C "$FOLD" add -A
git_fixture -C "$FOLD" commit -qm 'Create a synthetic verifier fixture'
PIN="$(git_fixture -C "$FOLD" rev-parse HEAD)"

cases=0
# run_case name mode reason exact-exit child-ran [environment overrides...]
# Every case starts with a prior PASS. Output files live outside the Git tree.
run_case() {
  local name="$1" mode="$2" reason="$3" want_rc="$4" child_ran="$5"
  shift 5
  local report="$WORK/reports/$SLUG.md" marker="$WORK/markers/$name" rc
  printf 'PASS\nprior release claim\n' >"$report"
  if (
    cd "$WORK/caller"
    env NORTH_STAR_PROOF_DIR=../reports NORTH_STAR_PROOF_MODE="$mode" \
      CLOUD_OWNED_GC_FOLD_SOURCE="$FOLD" CLOUD_OWNED_GC_FOLD_SOURCE_OID="$PIN" \
      EXPECTED_FOLD="$FOLD" EXPECTED_REPORT="$report" CHILD_MARKER="$marker" \
      TMPDIR="$WORK/tmp" "$@" bash "${CASE_HARNESS:-$HARNESS}"
  ) >"$WORK/$name.out" 2>&1; then rc=0; else rc=$?; fi
  [ "$rc" -eq "$want_rc" ] || fail "$name: exit $rc, expected $want_rc"
  [ "$(sed -n '1p' "$report")" = FAIL ] || fail "$name: prior PASS survived"
  grep -qx "Reason: $reason" "$report" || fail "$name: wrong failure reason"
  if [ "$child_ran" = yes ]; then
    [ -f "$marker" ] || fail "$name: child did not reach its assertions"
  else
    [ ! -e "$marker" ] || fail "$name: forbidden child execution"
  fi
  if grep -q 'SYNTHETIC_CHILD_SECRET_DO_NOT_PERSIST' "$report" "$WORK/$name.out"; then
    fail "$name: raw child output escaped"
  fi
  cases=$((cases + 1))
}

# Registration is independent of terminal success. The runner's list is safe.
bash "$RUNNER" --list | grep -qx "$SLUG" || fail 'slug is absent'

run_case offline offline FULL_RELEASE_PROOF_REQUIRES_LIVE_MODE 1 no
run_case unknown typo UNSUPPORTED_PROOF_MODE 1 no
run_case empty-mode '' UNSUPPORTED_PROOF_MODE 1 no
run_case no-source live FOLD_SOURCE_REQUIRED 1 no CLOUD_OWNED_GC_FOLD_SOURCE=
run_case absent-source live FOLD_SOURCE_MISSING 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/absent"
run_case no-pin live FOLD_SOURCE_PIN_REQUIRED 1 no CLOUD_OWNED_GC_FOLD_SOURCE_OID=
run_case malformed-pin live FOLD_SOURCE_PIN_INVALID 1 no CLOUD_OWNED_GC_FOLD_SOURCE_OID=main
run_case wrong-pin live FOLD_SOURCE_PIN_MISMATCH 1 no CLOUD_OWNED_GC_FOLD_SOURCE_OID=ffffffffffffffffffffffffffffffffffffffff

mkdir -p "$WORK/portal/.portal" "$WORK/archive/scripts" "$FOLD/subdirectory"
cp "$FOLD/scripts/prove-cloud-owned-gc" "$WORK/archive/scripts/prove-cloud-owned-gc"
ln -s "$WORK/portal" "$WORK/portal-link"
run_case portal live FOLD_SOURCE_IS_PORTAL 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/portal"
run_case portal-alias live FOLD_SOURCE_IS_PORTAL 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/portal-link"
run_case archive live FOLD_SOURCE_NOT_GIT_ROOT 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/archive"
run_case nested live FOLD_SOURCE_NOT_GIT_ROOT 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$FOLD/subdirectory"

clone_fixture() {
  git_fixture clone -q --no-hardlinks "$FOLD" "$WORK/$1"
}
clone_fixture dirty
printf 'changed\n' >>"$WORK/dirty/control"
run_case dirty live FOLD_SOURCE_DIRTY 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/dirty"
git_fixture -C "$WORK/dirty" add control
run_case staged live FOLD_SOURCE_DIRTY 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/dirty"
clone_fixture untracked
printf 'extra\n' >"$WORK/untracked/extra"
run_case untracked live FOLD_SOURCE_DIRTY 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/untracked"
clone_fixture hidden-dirty
git_fixture -C "$WORK/hidden-dirty" update-index --assume-unchanged scripts/prove-cloud-owned-gc
printf '\n# changed behind the index stat cache\n' >>"$WORK/hidden-dirty/scripts/prove-cloud-owned-gc"
run_case hidden-dirty live VERIFIER_BYTES_MISMATCH 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/hidden-dirty"
clone_fixture hidden-dependency
git_fixture -C "$WORK/hidden-dependency" update-index --assume-unchanged control
printf 'hidden dependency change\n' >>"$WORK/hidden-dependency/control"
run_case hidden-dependency live FOLD_SOURCE_INDEX_FLAGS_UNSAFE 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/hidden-dependency"
clone_fixture skipped-dependency
git_fixture -C "$WORK/skipped-dependency" update-index --skip-worktree control
run_case skipped-dependency live FOLD_SOURCE_INDEX_FLAGS_UNSAFE 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/skipped-dependency"
clone_fixture missing
git_fixture -C "$WORK/missing" rm -q scripts/prove-cloud-owned-gc
git_fixture -C "$WORK/missing" commit -qm 'No P9 verifier'
MISSING_PIN="$(git_fixture -C "$WORK/missing" rev-parse HEAD)"
run_case missing-verifier live MISSING_FOLD_P9_VERIFIER 1 no \
  CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/missing" CLOUD_OWNED_GC_FOLD_SOURCE_OID="$MISSING_PIN"
mkdir -p "$WORK/missing/scripts"
cp "$FOLD/scripts/prove-cloud-owned-gc" "$WORK/missing/scripts/prove-cloud-owned-gc"
run_case untracked-verifier live VERIFIER_NOT_PINNED 1 no \
  CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/missing" CLOUD_OWNED_GC_FOLD_SOURCE_OID="$MISSING_PIN"
clone_fixture non-executable
chmod -x "$WORK/non-executable/scripts/prove-cloud-owned-gc"
run_case non-executable live VERIFIER_NOT_EXECUTABLE 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/non-executable"
clone_fixture linked-verifier
git_fixture -C "$WORK/linked-verifier" rm -q scripts/prove-cloud-owned-gc
mkdir -p "$WORK/linked-verifier/scripts"
ln -s "$FOLD/scripts/prove-cloud-owned-gc" "$WORK/linked-verifier/scripts/prove-cloud-owned-gc"
run_case linked-verifier live VERIFIER_SYMLINK_REFUSED 1 no CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/linked-verifier"

# Live accepts a clean pinned DEV source for invocation, never for full PASS.
for output in empty pass malformed json private incomplete checklist; do
  run_case "zero-$output" live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes FAKE_OUTPUT="$output"
done
run_case nonzero live VERIFIER_NONZERO_EXIT 7 yes FAKE_OUTPUT=pass FAKE_RC=7
run_case secret-zero live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes FAKE_OUTPUT=secret
run_case secret-failure live VERIFIER_NONZERO_EXIT 9 yes FAKE_OUTPUT=secret FAKE_RC=9
run_case poisoned-report live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes FAKE_OUTPUT=poison-report
run_case bad-tmp live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes TMPDIR="$WORK/does-not-exist"
run_case relative-source live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes CLOUD_OWNED_GC_FOLD_SOURCE='../fold source'
run_case helper-override live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes CLOUD_OWNED_GC_FOLD_SOURCE= FOLD_REPO="$FOLD"
git_fixture -C "$FOLD" worktree add -q --detach "$WORK/dev-worktree" "$PIN"
run_case dev-worktree live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes \
  CLOUD_OWNED_GC_FOLD_SOURCE="$WORK/dev-worktree" EXPECTED_FOLD="$WORK/dev-worktree"

# Deprecated evidence paths cannot make the harness read or overwrite evidence.
printf 'PASS\nprivate evidence\n' >"$WORK/old-evidence.md"
run_case old-evidence live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes \
  CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE="$WORK/old-evidence.md" CLOUD_OWNED_GC_PROOF_NONCE=claimed
[ "$(cat "$WORK/old-evidence.md")" = $'PASS\nprivate evidence' ] || fail 'legacy evidence file changed'
run_case self-evidence live FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED 1 yes \
  CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE="$WORK/reports/$SLUG.md"

# Catchable exit and uncatchable death both leave FAIL, never the prior PASS.
run_case interrupted live HARNESS_INTERRUPTED 143 yes FAKE_OUTPUT=terminate
run_case killed live HARNESS_UNEXPECTED_EXIT 137 yes FAKE_OUTPUT=kill 2>"$WORK/expected-sigkill.err"
# Failure before helper loading must also replace a prior PASS. No production
# hooks are needed: a synthetic harness tree deliberately lacks common.sh.
mkdir -p "$WORK/broken/harness/north-star/cloud-owned-gc"
cp "$HARNESS" "$WORK/broken/harness/north-star/cloud-owned-gc/run.sh"
CASE_HARNESS="$WORK/broken/harness/north-star/cloud-owned-gc/run.sh" \
  run_case setup-failure live HARNESS_UNEXPECTED_EXIT 1 no

# Nothing writes a temporary raw child log, even on failure or interruption.
[ -z "$(ls -A "$WORK/tmp")" ] || fail 'temporary child output was persisted'

# The generic runner maps a nonzero harness to nonzero, not full success.
if NORTH_STAR_PROOF_DIR="$WORK/reports" NORTH_STAR_PROOF_MODE=unknown \
  bash "$RUNNER" "$SLUG" >"$WORK/runner.out" 2>&1; then
  fail 'runner accepted unknown mode'
fi
grep -qx FAIL "$WORK/reports/$SLUG.md" || fail 'runner lost failed report'

# The new test belongs at the append-only tail, just before the final guard.
# This rejects the mid-list registration from PR73 without a historical Git
# dependency (release archives and shallow CI checkouts need the same test).
check_ci_tail() {
  local entries entry='ci_test tests/last-stack-north-star-proof-cloud-owned-gc.sh'
  entries="$(sed -n '/^ci_test /p' "$1")"
  [ "$(printf '%s\n' "$entries" | grep -Fxc "$entry")" -eq 1 ] || return 1
  [ "$(printf '%s\n' "$entries" | tail -n 2)" = "$entry
ci_test tests/last-stack-ci-test-registration.sh" ]
}
check_ci_tail "$ROOT/.lastgit/ci.sh" || fail 'CI registration moved existing shard positions'
printf '%s\n' 'ci_test tests/old-a.sh' 'ci_test tests/old-b.sh' \
  'ci_test tests/last-stack-north-star-proof-cloud-owned-gc.sh' \
  'ci_test tests/last-stack-ci-test-registration.sh' >"$WORK/ci-tail.sh"
check_ci_tail "$WORK/ci-tail.sh" || fail 'valid append-only fixture failed'
printf '%s\n' 'ci_test tests/old-a.sh' \
  'ci_test tests/last-stack-north-star-proof-cloud-owned-gc.sh' 'ci_test tests/old-b.sh' \
  'ci_test tests/last-stack-ci-test-registration.sh' >"$WORK/ci-middle.sh"
if check_ci_tail "$WORK/ci-middle.sh"; then fail 'mid-list CI fixture was accepted'; fi

printf 'PASS cloud-owned-gc rejection fixtures: %s cases; no full-release PASS path\n' "$cases"
