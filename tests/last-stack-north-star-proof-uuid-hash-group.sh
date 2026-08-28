#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/uuid-hash-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fold="$WORK/fold"
mkdir -p \
  "$fold/vendor/laststore/src" \
  "$fold/vendor/laststore/tests" \
  "$fold/fold_db/crates/core/src/fold_db_core/factory" \
  "$WORK/bin" "$WORK/primary"

cat >"$fold/vendor/laststore/src/options.rs" <<'EOF'
const DEFAULT_HASH_GROUP_WARM_MAX_HANDLES: usize = 64;
layout_mode: LayoutMode::HashGroup
hash_group_warm_bytes: DEFAULT_HASH_GROUP_WARM_BYTES
EOF
cat >"$fold/fold_db/crates/core/src/fold_db_core/factory/local.rs" <<'EOF'
adapter_open_creates_uuid_hash_group_home
adapter_open_serves_legacy_journal_records
EOF
printf '%s\n' 'the_descriptor_gauge_tracks_closes_as_well_as_opens' \
  >"$fold/vendor/laststore/tests/warm_set_handle_cap.rs"
printf '%s\n' 'every_enumerated_plain_chunk_verifies_on_hash_group_home' \
  >"$fold/vendor/laststore/tests/plain_seg_backup_addressing.rs"
printf '%s\n' 'hash_group_sealed_chunk_corruption_quarantines_and_install_chunk_restores' \
  >"$fold/vendor/laststore/tests/fault_injection.rs"

cat >"$WORK/cow.md" <<'EOF'
PASS
source_layout: segment_log -> destination_layout: hash_group
total_documents: 11,472,142
source_unchanged: true
cloud_sync_copied: false
promoted: false
survived clean stop and restart
EOF

cat >"$WORK/bin/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UUID_HASH_GROUP_TEST_CARGO_LOG"
EOF
cat >"$WORK/bin/brain" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Tom's /goal authorized the operation.
The old cloud-sync pause Situation was already resolved.
cloud_sync.json restored and re-enabled.
OUT
EOF
cat >"$WORK/bin/lastdb" <<'EOF'
#!/usr/bin/env bash
echo 'Sync: state=Clean local_writable=true'
EOF
chmod +x "$WORK/bin/cargo" "$WORK/bin/brain" "$WORK/bin/lastdb"
printf '%s\n' fixture >"$WORK/primary/cloud_sync.json"

PATH="$WORK/bin:$PATH" \
FOLD_REPO="$fold" \
UUID_HASH_GROUP_COW_PROOF_FILE="$WORK/cow.md" \
UUID_HASH_GROUP_PRIMARY_HOME="$WORK/primary" \
UUID_HASH_GROUP_CARGO_TARGET_DIR="$WORK/target" \
UUID_HASH_GROUP_TEST_CARGO_LOG="$WORK/cargo.log" \
NORTH_STAR_PROOF_DIR="$WORK/reports" \
  "$RUNNER" --live north-star-lastdb-uuid-hash-group-addressing >"$WORK/out"

report="$WORK/reports/north-star-lastdb-uuid-hash-group-addressing.md"
test "$(sed -n '1p' "$report")" = PASS
grep -q '11,472,142 documents' "$report"
grep -q 'Tom-authorized sync configuration remained byte-identical' "$report"
test "$(wc -l <"$WORK/cargo.log" | tr -d ' ')" -eq 5

sed 's/promoted: false/promoted: true/' "$WORK/cow.md" >"$WORK/bad-cow.md"
if PATH="$WORK/bin:$PATH" \
  FOLD_REPO="$fold" \
  UUID_HASH_GROUP_COW_PROOF_FILE="$WORK/bad-cow.md" \
  UUID_HASH_GROUP_PRIMARY_HOME="$WORK/primary" \
  NORTH_STAR_PROOF_DIR="$WORK/bad-reports" \
    "$RUNNER" --offline north-star-lastdb-uuid-hash-group-addressing >/dev/null 2>&1; then
  echo 'FAIL: promoted CoW evidence was accepted' >&2
  exit 1
fi
test "$(sed -n '1p' "$WORK/bad-reports/north-star-lastdb-uuid-hash-group-addressing.md")" = FAIL

echo 'PASS last-stack-north-star-proof-uuid-hash-group'
