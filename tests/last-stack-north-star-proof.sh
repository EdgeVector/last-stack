#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-north-star-proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-proof-test.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fold="$WORK/edgevector/fold"
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

chmod +x "$BIN"
"$BIN" --list >"$WORK/list.out"
grep -q '^north-star-lastdb-file-blobs-on-demand-sync$' "$WORK/list.out"

EDGEVECTOR_WORKSPACE="$WORK/edgevector" \
NORTH_STAR_PROOF_DIR="$WORK/proofs" \
FOLD_FILE_BLOB_PROOF_RUN_CARGO=0 \
  "$BIN" --offline north-star-lastdb-file-blobs-on-demand-sync >"$WORK/proof.out"

report="$WORK/proofs/north-star-lastdb-file-blobs-on-demand-sync.md"
test -f "$report"
test "$(sed -n '1p' "$report")" = "PASS-OFFLINE"
grep -q "metadata-only" "$report"
grep -q "on-demand" "$report"
grep -q "cache" "$report"
grep -q "no bulk" "$report"
grep -q "cargo test -p fold_db" "$report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$WORK/proof.out"

echo "PASS last-stack-north-star-proof"
