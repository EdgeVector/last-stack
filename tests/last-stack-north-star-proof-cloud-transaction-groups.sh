#!/usr/bin/env bash
# Offline contract for north-star-lastdb-cloud-transaction-groups.
# Uses a fixture pin-log and a redacted evidence file. Does not open a LastDB home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-lastdb-cloud-transaction-groups/run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/txn-group-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-cloud-transaction-groups: $*" >&2
  exit 1
}

bash -n "$HARNESS"

"$RUNNER" --list | grep -qx 'north-star-lastdb-cloud-transaction-groups' ||
  fail "--list omits north-star-lastdb-cloud-transaction-groups"

write_pin_log() {
  local path="$1" schema_line="$2"
  cat >"$path" <<EOF
$schema_line
const TRANSACTION_GROUP_WIRE_VERSION: u32 = 2;

fn transaction_group_id(
    record: &PinLogRecord,
    record_digest_version: u32,
    record_sha256: &str,
) -> String {
    String::new()
}

async fn seal_transaction_group(
    record: &PinLogRecord,
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogSegment>, String> {
    if schemas.len() < 2 {
        return Err("transaction group requires more than one schema".to_string());
    }
    let wire = TransactionGroupWireV2::Shard {
        format_version: TRANSACTION_GROUP_WIRE_VERSION,
        group_id: group_id.clone(),
        writer_id: writer.to_string(),
        frontier_after: record.frontier_after,
        schema_name: schema_name.clone(),
        shard_index,
        shard_count,
        operations,
    };
    objects.push(MutationLogSegment { segment, payload });
    let manifest_segment = MutationLogSegmentId::schema_folder(
        writer,
        TRANSACTION_GROUP_MANIFEST_SCHEMA,
        utc_nanos,
        record.frontier_after,
        record.frontier_after,
    );
    let manifest_wire = TransactionGroupWireV2::Manifest {
        group_id,
        writer_id: writer.to_string(),
        frontier_after: record.frontier_after,
        shard_count,
    };
    Ok(objects)
}

async fn seal_mutation_log_publish_unit(
    records: &[PinLogRecord],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogSegment>, String> {
    if records.len() == 1
        && matches!(
            mutation_log_record_stream(&records[0])?,
            MutationLogRecordStream::MultiSchema
        )
    {
        return seal_transaction_group(&records[0], crypto).await;
    }
    Ok(vec![
        seal_mutation_log_segment_batch(records, crypto).await?,
    ])
}

async fn open_mutation_log_replay_units(
    segments: &[MutationLogSegment],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogReplayUnit>, String> {
    units.push(MutationLogReplayUnit {
        transaction_group: false,
    });
    let _ = "transaction group {group_id} has shards but no commit manifest";
    let _ = "transaction group {group_id} shard count does not match its manifest";
    Ok(units)
}

async fn multi_schema_cloud_publish_failure_keeps_record_and_frontier() {
    assert_eq!(mutation_log.frontier_f, frontier_before);
    assert_eq!(mutation_log.segments_uploaded, 0);
}

async fn transaction_group_seals_one_shard_per_schema_and_a_manifest_last() {
    let _ = TRANSACTION_GROUP_MANIFEST_SCHEMA;
    let _ = "a retry must use stable object keys";
}

async fn transaction_group_without_manifest_fails_before_replay() {
    assert!(error.contains("no commit manifest"), "{error}");
}

async fn transaction_group_with_missing_shard_fails_before_replay() {
    assert!(error.contains("shard count"), "{error}");
}

async fn transaction_group_rejects_a_resealed_shard_not_named_by_manifest() {
    assert!(error.contains("manifest validation"), "{error}");
}
EOF
}

write_evidence() {
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

expect_verdict() {
  local report="$1" want="$2" got
  got="$(sed -n '1p' "$report")"
  [ "$got" = "$want" ] || fail "first line is $got, want $want"
}

SCHEMA_LINE='const TRANSACTION_GROUP_MANIFEST_SCHEMA: &str = "__lastdb_transaction_group_v2__";'
write_pin_log "$WORK/pin_log.rs" "$SCHEMA_LINE"
write_evidence "$WORK/good.json" false

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
CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/pin_log.rs" \
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

PATH="$WORK/bin:$PATH" \
CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/pin_log.rs" \
CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/good.json" \
NORTH_STAR_PROOF_DIR="$WORK/good" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/good.out"
[ ! -e "$MARKER" ] || fail "the evidence path called lastdb or brain"
expect_verdict "$WORK/good/north-star-lastdb-cloud-transaction-groups.md" PASS-OFFLINE
grep -q 'Operational evidence: PASS' "$WORK/good/north-star-lastdb-cloud-transaction-groups.md"
"$EVALUATOR" --kind validation \
  --predicate "file $WORK/good/north-star-lastdb-cloud-transaction-groups.md matches /^PASS/" \
  >"$WORK/good-eval.out"
grep -q '^satisfied:' "$WORK/good-eval.out" || fail "PASS-OFFLINE did not satisfy /^PASS/"

write_evidence "$WORK/cutover.json" true
if PATH="$WORK/bin:$PATH" \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/pin_log.rs" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/cutover.json" \
  NORTH_STAR_PROOF_DIR="$WORK/cutover" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/cutover.out" 2>&1; then
  fail "a live cutover evidence file was accepted"
fi
expect_verdict "$WORK/cutover/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'primary home closed' "$WORK/cutover/north-star-lastdb-cloud-transaction-groups.md"

write_pin_log "$WORK/broken.rs" 'const TRANSACTION_GROUP_MANIFEST_SCHEMA: &str = "missing";'
if CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/broken.rs" \
  CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  NORTH_STAR_PROOF_DIR="$WORK/broken" \
  "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/broken.out" 2>&1; then
  fail "a pin-log source without the manifest schema was accepted"
fi
expect_verdict "$WORK/broken/north-star-lastdb-cloud-transaction-groups.md" FAIL
grep -q 'lacks the group manifest schema' "$WORK/broken/north-star-lastdb-cloud-transaction-groups.md"

mkdir -p "$WORK/home/.lastdb"
printf '%s\n' 'primary' >"$WORK/home/.lastdb/pin_log.rs"
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

if CLOUD_TRANSACTION_GROUPS_ALLOW_CUTOVER=1 \
  CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE="$WORK/pin_log.rs" \
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

PORTAL="$(ns_edgevector_workspace 2>/dev/null || true)"
if [ -z "${PORTAL:-}" ]; then
  PORTAL="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}"
fi
if [ -f "$PORTAL/fold/.portal/cache" ]; then
  if NORTH_STAR_PROOF_DIR="$WORK/real" \
    "$RUNNER" --offline north-star-lastdb-cloud-transaction-groups >"$WORK/real.out" 2>"$WORK/real.err"; then
    fail "real Fold source without operational evidence passed"
  fi
  expect_verdict "$WORK/real/north-star-lastdb-cloud-transaction-groups.md" FAIL
  grep -q 'Source contract: PASS' "$WORK/real/north-star-lastdb-cloud-transaction-groups.md" ||
    fail "real Fold pin-log source failed the product contract"
  grep -q 'Operational evidence: ABSENT' "$WORK/real/north-star-lastdb-cloud-transaction-groups.md"
fi

echo "PASS last-stack-north-star-proof-cloud-transaction-groups"
