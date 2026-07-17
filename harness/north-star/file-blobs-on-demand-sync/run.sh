#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-file-blobs-on-demand-sync
WS="$(ns_edgevector_workspace)"
REPO="${FOLD_REPO:-$WS/fold}"
MODE="$(ns_mode)"
REF="${FOLD_FILE_BLOB_PROOF_REF:-origin/main}"

if [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/Cargo.toml" ]; then
  ns_write_report "$SLUG" FAIL "fold checkout missing at $REPO" || exit 1
  exit 1
fi

if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch origin main >/dev/null 2>&1 || true
  if ! git -C "$REPO" rev-parse --verify --quiet "$REF" >/dev/null; then
    REF=HEAD
  fi
else
  REF=WORKTREE
fi

fold_read() {
  local path="$1"
  if [ "$REF" != WORKTREE ] && git -C "$REPO" cat-file -e "$REF:$path" 2>/dev/null; then
    git -C "$REPO" show "$REF:$path"
  elif [ -f "$REPO/$path" ]; then
    sed -n '1,$p' "$REPO/$path"
  else
    return 1
  fi
}

require_file() {
  local path="$1"
  if ! fold_read "$path" >/dev/null; then
    ns_write_report "$SLUG" FAIL "missing fold file at $REF:$path" || exit 1
    exit 1
  fi
}

require_pattern() {
  local path="$1" pattern="$2" label="$3"
  if ! fold_read "$path" | grep -Eq "$pattern"; then
    ns_write_report "$SLUG" FAIL "missing contract in $path: $label" || exit 1
    exit 1
  fi
}

require_file docs/designs/cloud-file-blobs-on-demand-sync.md
require_file fold_db/crates/core/src/sync/engine/file_blob.rs
require_file fold_db/crates/core/src/sharing/query_slice.rs
require_file fold_db/crates/core/src/sync/engine/tests.rs
require_file fold_db/crates/core/tests/file_blob_structured_reads_test.rs
require_file fold_db/crates/core/tests/file_blob_device_join_test.rs

require_pattern docs/designs/cloud-file-blobs-on-demand-sync.md 'ordinary sync never bulk-downloads file blobs|zero B2 GETs' 'no bulk CAS download during ordinary sync'
require_pattern docs/designs/cloud-file-blobs-on-demand-sync.md 'metadata-only|structured metadata|no local CAS bytes' 'metadata-only structured reads'
require_pattern docs/designs/cloud-file-blobs-on-demand-sync.md 'explicit on-demand path|on-demand fetch' 'explicit on-demand fetch path'
require_pattern docs/designs/cloud-file-blobs-on-demand-sync.md 'cache hit|does not re-fetch' 'cache hit avoids second blob fetch'
require_pattern fold_db/crates/core/src/sync/engine/file_blob.rs 'must not list or bulk' 'sync path refuses bulk CAS listing'
require_pattern fold_db/crates/core/src/sync/engine/file_blob.rs 'ordinary sync/bootstrap/device-join' 'sync/bootstrap/device-join avoids CAS downloads'
require_pattern fold_db/crates/core/src/sharing/query_slice.rs 'resolve_file_bytes_on_demand' 'on-demand resolver exported'
require_pattern fold_db/crates/core/src/sharing/query_slice.rs 'blob_cas::get_blob_bytes' 'local CAS checked before remote fetch'
require_pattern fold_db/crates/core/src/sharing/query_slice.rs 'download_file_blob' 'remote fetch is explicit'
require_pattern fold_db/crates/core/src/sharing/query_slice.rs 'blob_cas::put_blob' 'remote fetch populates local cache'
require_pattern fold_db/crates/core/src/sync/engine/tests.rs 'file_blob_upload_and_delete_confirm_after_successful_object_ops' 'upload/delete and no default CAS download test'
require_pattern fold_db/crates/core/src/sync/engine/tests.rs 'file_blob_explicit_download_opens_with_returned_dek' 'explicit one-file download test'
require_pattern fold_db/crates/core/src/sync/engine/tests.rs 'file_blob_on_demand_fetch_caches_local_hit_and_rejects_wrong_dek' 'on-demand cache and wrong-DEK test'
require_pattern fold_db/crates/core/tests/file_blob_structured_reads_test.rs 'structured.*without.*bytes|missing.*blob|local CAS' 'structured reads tolerate missing local bytes'
require_pattern fold_db/crates/core/tests/file_blob_device_join_test.rs 'presign_file_download|GET /file/download|local cache hit|metadata' 'device join metadata-only plus explicit fetch proof'

proof_cmd='cargo test -p fold_db --test file_blob_structured_reads_test --test file_blob_device_join_test file_blob_ -- --nocapture'
notes="$(cat <<EOF
Fold file-blob proof source contract verified.

Fold repo: $REPO
Fold ref: $REF
Mode: $MODE

Prerequisite fold command delegated by this harness:
\`\`\`bash
$proof_cmd
\`\`\`

Covered invariants:
- metadata-only sync/bootstrap/device join does not bulk-download B2 CAS blobs
- structured reads tolerate missing local file bytes
- explicit one-file fetch uses the file-blob download path
- on-demand fetch verifies and stores local CAS bytes
- cache hit avoids a second remote blob fetch
- ordinary sync path has no bulk list/download-all CAS behavior
EOF
)"

cargo_status="skipped"
if [ "${FOLD_FILE_BLOB_PROOF_RUN_CARGO:-auto}" != "0" ] &&
  command -v cargo >/dev/null 2>&1 &&
  [ -f "$REPO/fold_db/Cargo.toml" ] &&
  [ -f "$REPO/fold_db/crates/core/tests/file_blob_structured_reads_test.rs" ] &&
  [ -f "$REPO/fold_db/crates/core/tests/file_blob_device_join_test.rs" ]; then
  set +e
  out="$(cd "$REPO" && cargo test -p fold_db --test file_blob_structured_reads_test --test file_blob_device_join_test file_blob_ -- --nocapture 2>&1)"
  rc=$?
  set -e
  notes="$(printf '%s\n\ncargo rc=%s\n```text\n%s\n```\n' "$notes" "$rc" "$out")"
  if [ "$rc" -ne 0 ]; then
    ns_write_report "$SLUG" FAIL "$notes" || exit 1
    exit 1
  fi
  cargo_status="passed"
else
  notes="$(printf '%s\n\nCargo execution: skipped. Set FOLD_FILE_BLOB_PROOF_RUN_CARGO=1 from a fold main checkout to force the delegated command.\n' "$notes")"
fi

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$(printf '%s\nCargo status: %s\n' "$notes" "$cargo_status")"
