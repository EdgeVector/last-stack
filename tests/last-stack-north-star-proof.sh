#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-proof"
chmod +x "$BIN" "$ROOT/harness/north-star"/*/run.sh

"$BIN" --list | grep -q north-star-coderings
"$BIN" --list | grep -q north-star-schema-shared-surface-native-resolver
"$BIN" --list | grep -q north-star-lastdb-file-blobs-on-demand-sync

PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ns-proof-test.XXXXXX")"
FILE_BLOB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-file-blob-proof-test.XXXXXX")"
trap 'rm -rf "$PROOF_DIR" "$FILE_BLOB_WORK"' EXIT
export NORTH_STAR_PROOF_DIR="$PROOF_DIR"
export NORTH_STAR_PROOF_MODE=offline
export EDGEVECTOR_WORKSPACE="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}"

# Always-safe offline proofs when checkouts exist
if [ -d "$EDGEVECTOR_WORKSPACE/coderings" ]; then
  "$BIN" --offline north-star-coderings
  head -1 "$PROOF_DIR/north-star-coderings.md" | grep -qE '^PASS'
fi

if command -v lastdb >/dev/null 2>&1; then
  "$BIN" --offline north-star-app-ops-latency
  head -1 "$PROOF_DIR/north-star-app-ops-latency.md" | grep -qE '^PASS'
fi

# Structural: all harness scripts exist and bash -n clean
for s in coderings deliver-slices lastgit metering minimal-node app-ops schema file-blobs-on-demand-sync; do
  bash -n "$ROOT/harness/north-star/$s/run.sh"
done
bash -n "$BIN"
bash -n "$ROOT/harness/north-star/common.sh"

fold="$FILE_BLOB_WORK/edgevector/fold"
mkdir -p \
  "$fold/docs/designs" \
  "$fold/fold_db/crates/core/src/sync/engine" \
  "$fold/fold_db/crates/core/src/sharing" \
  "$fold/fold_db/crates/core/tests"
touch "$fold/Cargo.toml"

cat >"$fold/docs/designs/cloud-file-blobs-on-demand-sync.md" <<'EOF'
ordinary sync never bulk-downloads file blobs. metadata-only structured metadata
supports no local CAS bytes. explicit on-demand path. cache hit does not re-fetch.
EOF
cat >"$fold/fold_db/crates/core/src/sync/engine/file_blob.rs" <<'EOF'
//! must not list or bulk download during ordinary sync/bootstrap/device-join
EOF
cat >"$fold/fold_db/crates/core/src/sharing/query_slice.rs" <<'EOF'
fn resolve_file_bytes_on_demand() {
  blob_cas::get_blob_bytes();
  download_file_blob();
  blob_cas::put_blob();
}
EOF
cat >"$fold/fold_db/crates/core/src/sync/engine/tests.rs" <<'EOF'
fn file_blob_upload_and_delete_confirm_after_successful_object_ops() {}
fn file_blob_explicit_download_opens_with_returned_dek() {}
fn file_blob_on_demand_fetch_caches_local_hit_and_rejects_wrong_dek() {}
EOF
cat >"$fold/fold_db/crates/core/tests/file_blob_structured_reads_test.rs" <<'EOF'
fn structured_reads_without_bytes_missing_blob_local_CAS() {}
EOF
cat >"$fold/fold_db/crates/core/tests/file_blob_device_join_test.rs" <<'EOF'
fn device_join_metadata_only() {
  "presign_file_download";
  "GET /file/download";
  "local cache hit";
  "metadata";
}
EOF

EDGEVECTOR_WORKSPACE="$FILE_BLOB_WORK/edgevector" \
NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
FOLD_FILE_BLOB_PROOF_RUN_CARGO=0 \
  "$BIN" --offline north-star-lastdb-file-blobs-on-demand-sync >"$FILE_BLOB_WORK/proof.out"

report="$PROOF_DIR/north-star-lastdb-file-blobs-on-demand-sync.md"
test -f "$report"
test "$(sed -n '1p' "$report")" = "PASS-OFFLINE"
grep -q "metadata-only" "$report"
grep -q "on-demand" "$report"
grep -q "cache" "$report"
grep -q "no bulk" "$report"
grep -q "cargo test -p fold_db" "$report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$FILE_BLOB_WORK/proof.out"

echo "PASS last-stack-north-star-proof"
