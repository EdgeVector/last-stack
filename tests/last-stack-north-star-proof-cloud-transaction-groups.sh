#!/usr/bin/env bash
# Offline contract for north-star-lastdb-cloud-transaction-groups.
# The positive source check reads the pinned Fold pin_log.rs.
# It does not open a LastDB home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-lastdb-cloud-transaction-groups/run.sh"
PIN_DIR="$ROOT/tests/fixtures/north-star-lastdb-cloud-transaction-groups"
PINNED="$PIN_DIR/pin_log.rs"
PIN_META="$PIN_DIR/PIN"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/txn-group-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-cloud-transaction-groups: $*" >&2
  exit 1
}

bash -n "$HARNESS"

"$RUNNER" --list | grep -qx 'north-star-lastdb-cloud-transaction-groups' ||
  fail "--list omits north-star-lastdb-cloud-transaction-groups"

[ -f "$PINNED" ] || fail "pinned pin_log.rs is absent: $PINNED"
[ -f "$PIN_META" ] || fail "pin metadata is absent: $PIN_META"
want_sha="$(sed -n 's/^sha256:[[:space:]]*//p' "$PIN_META")"
got_sha="$(shasum -a 256 "$PINNED" | awk '{print $1}')"
[ -n "$want_sha" ] && [ "$got_sha" = "$want_sha" ] ||
  fail "pinned pin_log.rs hash does not match the pin"
if grep -q 'let _ = "transaction group' "$PINNED"; then
  fail "pinned pin_log.rs satisfies the source contract with unused string literals"
fi

write_boolean_evidence() {
  local path="$1" cutover="$2"
  cat >"$path" <<EOF
{
  "schema": "lastdb-cloud-transaction-groups-proof.v1",
  "surface": {
    "kind": "cow",
    "primary_home_opened": false,
    "primary_mutated": false,
    "live_cutover": $cutover
  },
  "frontier_drain": {
    "frontier": "1787974212509104000",
    "drained_on_cow_copy": true,
    "deleted": false,
    "quarantined": false
  },
  "publish": {
    "failed_upload_leaves_frontier_unchanged": true,
    "retry_idempotent": true
  },
  "restore": {
    "empty_home": true,
    "brain_primary_reproduced": true,
    "projections_exact": true,
    "v1_single_schema_valid": true,
    "partial_group_advances_restore_frontier": false
  },
  "canary": {
    "safe_upgrade_before_start": true,
    "soak_hours": 24,
    "live_canary_passed": true
  }
}
EOF
}

write_measured() {
  local path="$1"
  local cutover="${2:-false}"
  local soak_end="${3:-2026-08-31T22:59:52Z}"
  local published_after="${4:-1788069523520522000}"
  cat >"$path" <<EOF
{
  "schema": "lastdb-cloud-transaction-groups-proof.v1",
  "surface": {
    "kind": "cow",
    "primary_home_opened": false,
    "primary_mutated": false,
    "live_cutover": $cutover
  },
  "cow_output": "frontier: 1787974212509104000\npublished_through_before: 1787900000000000000\npublished_through_after: ${published_after}\npin_rows_before: 12\npin_rows_after: 11\ndeleted: 0\nquarantined: 0\nfailed_upload_frontier_before: 1787974212509104000\nfailed_upload_frontier_after: 1787974212509104000\nretry_object_count: 4\nretry_new_keys: 0\n",
  "restore_output": "primary_records: 1046\nrestored_records: 1046\nprimary_projection_sha256: 24b454bc2a4368edcc45b53a423c08b14350c612fe52adfcbcd1b04cd6f2db9c\nrestored_projection_sha256: 24b454bc2a4368edcc45b53a423c08b14350c612fe52adfcbcd1b04cd6f2db9c\nv1_records: 3\nv1_restored_records: 3\npartial_group_frontier_before: 1787974212509104000\npartial_group_frontier_after: 1787974212509104000\n",
  "soak_output": "safe_upgrade_at: 2026-08-30T22:59:52Z\nsoak_started_at: 2026-08-30T22:59:52Z\nsoak_ended_at: ${soak_end}\ncanary_started_at: 2026-08-31T23:00:00Z\n"
}
EOF
}

expect_verdict() {
  local report="$1" want="$2" got
  got="$(sed -n '1p' "$report")"
  [ "$got" = "$want" ] || fail "first line is $got, want $want ($report)"
}

write_boolean_evidence "$WORK/booleans.json" false
write_measured "$WORK/good.json" false
write_measured "$WORK/short-soak.json" false "2026-08-30T23:59:52Z"
write_measured "$WORK/undrained.json" false "2026-08-31T22:59:52Z" "1787000000000000000"
write_measured "$WORK/cutover.json" true

MARKER="$WORK/home-opened"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/lastdb" <<EOF
#!/bin/sh
echo called >"$MARKER"
exit 99
EOF
cat >"$WORK/bin/brain" <<EOF
#!/bin/sh
echo called >"$MARKER"
exit 99
EOF
chmod +x "$WORK/bin/lastdb" "$WORK/bin/brain"

PATH="$WORK/bin:$PATH" \
CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
NORTH_STAR_PROOF_DIR="$WORK/absent" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/absent.out" 2>"$WORK/absent.err" || true
[ ! -e "$MARKER" ] || fail "the offline proof called lastdb or brain"
expect_verdict "$WORK/absent/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'Source contract: PASS' "$WORK/absent/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'Operational evidence: ABSENT' "$WORK/absent/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'The harness did not open a LastDB home.' "$WORK/absent/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'The harness did not start a cloud cutover.' "$WORK/absent/north-star-lastdb-cloud-transaction-groups.md"
if "$EVALUATOR" --kind validation \
  --predicate "file $WORK/absent/north-star-lastdb-cloud-transaction-groups.md matches /^PASS/" \
  >"$WORK/absent-eval.out"; then
  fail "a report without operational evidence satisfied /^PASS/"
fi
grep -q '^pending:' "$WORK/absent-eval.out" || fail "missing-evidence report was not pending"

if PATH="$WORK/bin:$PATH" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/booleans.json" \
  NORTH_STAR_PROOF_DIR="$WORK/booleans" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/booleans.out" 2>&1; then
  fail "a JSON file of booleans was accepted as operational evidence"
fi
expect_verdict "$WORK/booleans/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'Source contract: PASS' "$WORK/booleans/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'lacks measured CoW output' "$WORK/booleans/north-star-lastdb-cloud-transaction-groups.md"
if "$EVALUATOR" --kind validation \
  --predicate "file $WORK/booleans/north-star-lastdb-cloud-transaction-groups.md matches /^PASS/" \
  >"$WORK/booleans-eval.out"; then
  fail "boolean evidence satisfied /^PASS/"
fi
grep -q '^pending:' "$WORK/booleans-eval.out" || fail "boolean evidence was not pending"

PATH="$WORK/bin:$PATH" \
CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/good.json" \
NORTH_STAR_PROOF_DIR="$WORK/good" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/good.out"
[ ! -e "$MARKER" ] || fail "the evidence path called lastdb or brain"
expect_verdict "$WORK/good/north-star-lastdb-cloud-transaction-groups.md" PASS-OFFLINE
grep -q 'Operational evidence: PASS' "$WORK/good/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'published_through 1787900000000000000 to 1788069523520522000' \
  "$WORK/good/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'The soak window ran from 2026-08-30T22:59:52Z to 2026-08-31T22:59:52Z' \
  "$WORK/good/north-star-lastdb-cloud-transaction-groups.md"
"$EVALUATOR" --kind validation \
  --predicate "file $WORK/good/north-star-lastdb-cloud-transaction-groups.md matches /^PASS/" \
  >"$WORK/good-eval.out"
grep -q '^satisfied:' "$WORK/good-eval.out" || fail "PASS-OFFLINE did not satisfy /^PASS/"

if PATH="$WORK/bin:$PATH" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/short-soak.json" \
  NORTH_STAR_PROOF_DIR="$WORK/short" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/short.out" 2>&1; then
  fail "a soak window shorter than 24 hours was accepted"
fi
expect_verdict "$WORK/short/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'soak window is shorter than 24 hours' \
  "$WORK/short/north-star-lastdb-cloud-transaction-groups.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/undrained.json" \
  NORTH_STAR_PROOF_DIR="$WORK/undrained" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/undrained.out" 2>&1; then
  fail "CoW output that stays below the frontier was accepted"
fi
expect_verdict "$WORK/undrained/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'did not drain on the measured CoW output' \
  "$WORK/undrained/north-star-lastdb-cloud-transaction-groups.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/cutover.json" \
  NORTH_STAR_PROOF_DIR="$WORK/cutover" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/cutover.out" 2>&1; then
  fail "a live cutover evidence file was accepted"
fi
expect_verdict "$WORK/cutover/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'primary home closed' "$WORK/cutover/north-star-lastdb-cloud-transaction-groups.md"

sed 's/__lastdb_transaction_group_v2__/missing/' "$PINNED" >"$WORK/broken.rs"
if CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/broken.rs" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  NORTH_STAR_PROOF_DIR="$WORK/broken" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/broken.out" 2>&1; then
  fail "a pin-log source without the manifest schema was accepted"
fi
expect_verdict "$WORK/broken/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'lacks the group manifest schema' "$WORK/broken/north-star-lastdb-cloud-transaction-groups.md"

mkdir -p "$WORK/home/.lastdb"
cp "$PINNED" "$WORK/home/.lastdb/pin_log.rs"
if HOME="$WORK/home" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/home/.lastdb/pin_log.rs" \
  NORTH_STAR_PROOF_DIR="$WORK/primary" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/primary.out" 2>&1; then
  fail "a primary LastDB home path was accepted"
fi
expect_verdict "$WORK/primary/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'refuses a LastDB home path' "$WORK/primary/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'Source contract: PASS' "$WORK/primary/north-star-lastdb-cloud-transaction-groups.md" &&
  fail "the primary path was read as a source contract"

mkdir -p "$WORK/real-primary" "$WORK/link-home"
cp "$PINNED" "$WORK/real-primary/pin_log.rs"
ln -s "$WORK/real-primary" "$WORK/link-home/.lastdb"
ln -s "$WORK/real-primary" "$WORK/hop1"
ln -s "$WORK/hop1" "$WORK/hop2"
if HOME="$WORK/link-home" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/hop2/pin_log.rs" \
  NORTH_STAR_PROOF_DIR="$WORK/symlink" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/symlink.out" 2>&1; then
  fail "a directory symlink into the primary LastDB home was accepted"
fi
expect_verdict "$WORK/symlink/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'refuses a LastDB home path' "$WORK/symlink/north-star-lastdb-cloud-transaction-groups.md"
grep -q 'Source contract: PASS' "$WORK/symlink/north-star-lastdb-cloud-transaction-groups.md" &&
  fail "the primary path was read through a directory symlink"

if CLOUD_TRANSACTION_GROUPS_ALLOW_CUTOVER=1 \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$PINNED" \
  NORTH_STAR_PROOF_DIR="$WORK/allow" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/allow.out" 2>&1; then
  fail "a cutover switch was accepted"
fi
expect_verdict "$WORK/allow/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'does not start a cloud cutover' "$WORK/allow/north-star-lastdb-cloud-transaction-groups.md"

if NORTH_STAR_PROOF_MODE=sideways \
  NORTH_STAR_PROOF_DIR="$WORK/mode" \
  "$RUNNER" north-star-lastdb-cloud-transaction-groups >"$WORK/mode.out" 2>&1; then
  fail "an invalid proof mode was accepted"
fi
expect_verdict "$WORK/mode/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'proof mode is invalid' "$WORK/mode/north-star-lastdb-cloud-transaction-groups.md"

echo "PASS last-stack-north-star-proof-cloud-transaction-groups"
