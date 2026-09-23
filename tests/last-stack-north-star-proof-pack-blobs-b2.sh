#!/usr/bin/env bash
# Offline contract for north-star-lastgit-pack-blobs-b2-migration.
# The source check reads LastGit pack-file code. Measured evidence is required
# for a terminal pass. The harness does not open a LastDB home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-lastgit-pack-blobs-b2-migration/run.sh"
FIXTURE="$ROOT/tests/fixtures/north-star-lastgit-pack-blobs-b2-migration"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pack-blobs-b2-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-pack-blobs-b2: $*" >&2
  exit 1
}

bash -n "$HARNESS"
python3 -m py_compile "$ROOT/harness/north-star/north-star-lastgit-pack-blobs-b2-migration/check_contract.py"

"$RUNNER" --list | grep -qx 'north-star-lastgit-pack-blobs-b2-migration' ||
  fail "--list omits north-star-lastgit-pack-blobs-b2-migration"

OLDEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LARGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NEWEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

write_evidence() {
  local path="$1"
  shift
  cat >"$path" <<EOF
schema: lastgit-pack-blobs-b2-proof.v1
primary_home_opened: false
primary_mutated: false
live_cutover: false
reachable_pack_blobs: 4
pointerless_reachable: 0
backfill_first_failed: 0
backfill_second_uploaded: 0
backfill_second_failed: 0
backfill_second_skipped: 4
backfill_second_verify_pointers: true
oldest_sha256: ok $OLDEST
largest_sha256: ok $LARGEST
newest_sha256: ok $NEWEST
round_trip_source: b2
new_push_count: 2
new_push_pointerless: 0
disabled_plane_visible: true
silent_offsite_claim: false
pack_bytes_in_atoms: 0
db_sync_plane: r2
pack_file_plane: b2
EOF
  while [ "$#" -ge 2 ]; do
    key="$1"
    value="$2"
    awk -v key="$key" -v value="$value" '
      BEGIN { prefix = key ": " }
      index($0, prefix) == 1 { print prefix value; next }
      { print }
    ' "$path" >"$path.next"
    mv "$path.next" "$path"
    shift 2
  done
}

expect_verdict() {
  local report="$1" want="$2" got
  got="$(sed -n '1p' "$report")"
  [ "$got" = "$want" ] || fail "first line is $got, want $want"
}

run_proof() {
  local repo="$1" evidence="$2" report_dir="$3"
  shift 3
  mkdir -p "$report_dir"
  LASTGIT_REPO="$repo" \
    LASTGIT_PACK_BLOBS_B2_PROOF_EVIDENCE_FILE="$evidence" \
    LASTGIT_PACK_BLOBS_B2_RUN_BUN=0 \
    NORTH_STAR_PROOF_DIR="$report_dir" \
    NORTH_STAR_PROOF_MODE=offline \
    "$@" \
    "$RUNNER" --offline north-star-lastgit-pack-blobs-b2-migration
}

write_evidence "$WORK/good.txt"
write_evidence "$WORK/cutover.txt" live_cutover true
write_evidence "$WORK/primary.txt" primary_home_opened true
write_evidence "$WORK/r2-pack.txt" pack_file_plane r2
write_evidence "$WORK/upload-again.txt" backfill_second_uploaded 3
write_evidence "$WORK/no-verify.txt" backfill_second_verify_pointers false
printf '%s\n' '{"ok":true,"pass":true}' >"$WORK/booleans.json"

set +e
run_proof "$FIXTURE/good" "" "$WORK/no-evidence" >"$WORK/no-evidence.out"
no_evidence_rc=$?
set -e
[ "$no_evidence_rc" -ne 0 ] || fail "missing evidence returned success"
expect_verdict "$WORK/no-evidence/north-star-lastgit-pack-blobs-b2-migration.md" FAIL
grep -q 'Source contract: hold' "$WORK/no-evidence/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "good source did not hold without evidence"
grep -q 'The terminal backfill has no measured evidence.' "$WORK/no-evidence/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "missing evidence did not say so"
if grep -Eq '^PASS' "$WORK/no-evidence/north-star-lastgit-pack-blobs-b2-migration.md"; then
  fail "a fail report matches ^PASS"
fi
"$EVALUATOR" --kind validation --predicate \
  "file $WORK/no-evidence/north-star-lastgit-pack-blobs-b2-migration.md matches /^PASS/" \
  >"$WORK/no-evidence-done.txt" && fail "DONE-WHEN closed a fail report"
grep -q 'pending:' "$WORK/no-evidence-done.txt" || fail "DONE-WHEN did not stay pending"

set +e
run_proof "$FIXTURE/decoy" "$WORK/good.txt" "$WORK/decoy" >"$WORK/decoy.out"
decoy_rc=$?
set -e
[ "$decoy_rc" -ne 0 ] || fail "comment-only source returned success"
expect_verdict "$WORK/decoy/north-star-lastgit-pack-blobs-b2-migration.md" FAIL
grep -q 'Source contract: broken' "$WORK/decoy/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "comment-only source counted as the contract"
grep -q 'Cover backfill is not the pack-blob migration.' "$WORK/decoy/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "cover backfill was accepted as this proof"

run_proof "$FIXTURE/good" "$WORK/good.txt" "$WORK/pass"
expect_verdict "$WORK/pass/north-star-lastgit-pack-blobs-b2-migration.md" PASS-OFFLINE
"$EVALUATOR" --kind validation --predicate \
  "file $WORK/pass/north-star-lastgit-pack-blobs-b2-migration.md matches /^PASS/" \
  >"$WORK/pass-done.txt"
grep -q 'satisfied:' "$WORK/pass-done.txt" || fail "DONE-WHEN did not accept the measured report"

for bad in cutover primary r2-pack upload-again no-verify; do
  set +e
  run_proof "$FIXTURE/good" "$WORK/$bad.txt" "$WORK/$bad" >"$WORK/$bad.out"
  bad_rc=$?
  set -e
  [ "$bad_rc" -ne 0 ] || fail "$bad evidence returned success"
  expect_verdict "$WORK/$bad/north-star-lastgit-pack-blobs-b2-migration.md" FAIL
done

set +e
run_proof "$FIXTURE/good" "$WORK/booleans.json" "$WORK/booleans" >"$WORK/booleans.out"
boolean_rc=$?
set -e
[ "$boolean_rc" -ne 0 ] || fail "boolean checklist returned success"
expect_verdict "$WORK/booleans/north-star-lastgit-pack-blobs-b2-migration.md" FAIL

mkdir -p "$WORK/fake-home/.lastdb"
set +e
HOME="$WORK/fake-home" \
  LASTGIT_REPO="$WORK/fake-home/.lastdb/pack-blobs-b2-proof-does-not-exist" \
  LASTGIT_PACK_BLOBS_B2_RUN_BUN=0 \
  NORTH_STAR_PROOF_DIR="$WORK/primary-path" \
  NORTH_STAR_PROOF_MODE=offline \
  "$RUNNER" --offline north-star-lastgit-pack-blobs-b2-migration >"$WORK/primary-path.out"
primary_rc=$?
set -e
[ "$primary_rc" -ne 0 ] || fail "a primary home path returned success"
expect_verdict "$WORK/primary-path/north-star-lastgit-pack-blobs-b2-migration.md" FAIL
grep -q 'The harness refuses a LastDB home path.' \
  "$WORK/primary-path/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "primary home path was not refused"

set +e
LASTGIT_REPO="$FIXTURE/good" \
  LASTGIT_PACK_BLOBS_B2_ALLOW_CUTOVER=1 \
  LASTGIT_PACK_BLOBS_B2_RUN_BUN=0 \
  NORTH_STAR_PROOF_DIR="$WORK/cutover-env" \
  NORTH_STAR_PROOF_MODE=offline \
  "$RUNNER" --offline north-star-lastgit-pack-blobs-b2-migration >"$WORK/cutover-env.out"
cutover_rc=$?
set -e
[ "$cutover_rc" -ne 0 ] || fail "a cutover flag returned success"
grep -q 'This harness does not start a B2 cutover.' \
  "$WORK/cutover-env/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "cutover flag was not refused"

mkdir -p "$WORK/archive/src" "$WORK/archive/test"
cp -R "$FIXTURE/good/src/." "$WORK/archive/src/"
printf '%s\n' 'test("pack file blob", () => {});' >"$WORK/archive/test/pack-file-blob.test.ts"
set +e
LASTGIT_REPO="$WORK/archive" \
  LASTGIT_PACK_BLOBS_B2_RUN_BUN=auto \
  NORTH_STAR_PROOF_DIR="$WORK/archive-proof" \
  NORTH_STAR_PROOF_MODE=offline \
  "$RUNNER" --offline north-star-lastgit-pack-blobs-b2-migration >"$WORK/archive.out"
archive_rc=$?
set -e
[ "$archive_rc" -ne 0 ] || fail "an archive without node_modules returned success"
grep -q 'Bun pack-file contract: skipped' \
  "$WORK/archive-proof/north-star-lastgit-pack-blobs-b2-migration.md" ||
  fail "an archive without node_modules ran or failed bun"
grep -q 'Bun pack-file contract: broken' \
  "$WORK/archive-proof/north-star-lastgit-pack-blobs-b2-migration.md" &&
  fail "missing node_modules was reported as a broken contract"

REAL="${LASTGIT_REPO_REAL:-$HOME/code/edgevector/lastgit}"
if [ -f "$REAL/src/client.ts" ] && [ -f "$REAL/src/cli.ts" ]; then
  set +e
  run_proof "$REAL" "" "$WORK/real" >"$WORK/real.out"
  real_rc=$?
  set -e
  [ "$real_rc" -ne 0 ] || fail "real LastGit source returned success without evidence"
  expect_verdict "$WORK/real/north-star-lastgit-pack-blobs-b2-migration.md" FAIL
  grep -q 'Source contract: hold' "$WORK/real/north-star-lastgit-pack-blobs-b2-migration.md" ||
    fail "real LastGit source did not satisfy the pack-file contract: $(sed -n '1,80p' "$WORK/real/north-star-lastgit-pack-blobs-b2-migration.md")"
fi

echo "PASS last-stack-north-star-proof-pack-blobs-b2"
