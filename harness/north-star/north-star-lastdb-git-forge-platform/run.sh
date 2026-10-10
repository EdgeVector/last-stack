#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-git-forge-platform
# Offline terminal proof for the LastDB Git Forge Platform.
# Reads the merged Fold grant/blob contract. Does not open a LastDB home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-git-forge-platform
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-git-forge-proof.XXXXXX")"

HANDLERS_REL=exemem_service/lambdas/storage_service/src/handlers.rs
REQUEST_REL=exemem_service/lambdas/storage_service/src/main.rs
AUTH_REL=fold_db/crates/core/src/sync/auth/ops/guaranteed_write.rs
AUTH_TESTS_REL=fold_db/crates/core/src/sync/auth/tests.rs

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

finish() {
  local verdict="$1" body="$2"
  if [ "$verdict" = FAIL ]; then
    ns_write_report "$SLUG" FAIL "$body" || true
    exit 1
  fi
  ns_write_report "$SLUG" "$verdict" "$body"
  exit 0
}

canonical_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

refuse_primary() {
  local candidate="$1" canon root root_canon
  [ -n "$candidate" ] || return 0
  canon="$(canonical_path "$candidate")" || finish FAIL "The harness could not resolve: $candidate."
  for root in "$HOME/.lastdb" "$HOME/.folddb"; do
    root_canon="$(canonical_path "$root")" || finish FAIL "The harness could not resolve the primary LastDB home."
    case "$canon" in
      "$root_canon"|"$root_canon"/*)
        finish FAIL "The harness refuses a primary LastDB path: $candidate."
        ;;
    esac
  done
}

line_of() {
  local file="$1" needle="$2"
  rg -n -F -- "$needle" "$file" | sed -n '1s/:.*//p'
}

FAILURES=()
require_text() {
  local file="$1" needle="$2" description="$3"
  if ! rg -F -q -- "$needle" "$file"; then
    FAILURES+=("missing ${description} in ${file}")
  fi
}

require_order_after() {
  local file="$1" anchor="$2" first="$3" second="$4" description="$5"
  local anchor_line first_line second_line
  anchor_line="$(line_of "$file" "$anchor" || true)"
  if [ -z "$anchor_line" ]; then
    FAILURES+=("cannot find ${description} anchor")
    return
  fi
  first_line="$(rg -n -F -- "$first" "$file" | awk -F: -v start="$anchor_line" '$1 > start { print $1; exit }')"
  second_line="$(rg -n -F -- "$second" "$file" | awk -F: -v start="$anchor_line" '$1 > start { print $1; exit }')"
  if [ -z "$first_line" ] || [ -z "$second_line" ]; then
    FAILURES+=("cannot establish order for ${description}")
  elif [ "$first_line" -ge "$second_line" ]; then
    FAILURES+=("${description} is out of order (${first_line} then ${second_line})")
  fi
}

case "$MODE" in
  offline) ;;
  live)
    refuse_primary "$(ns_proof_dir)"
    finish FAIL "This harness runs in offline mode only. It does not open a LastDB home or run cloud infrastructure."
    ;;
  *)
    refuse_primary "$(ns_proof_dir)"
    finish FAIL "The proof mode is invalid: $MODE."
    ;;
esac

refuse_primary "$(ns_proof_dir)"

SOURCE_ROOT="${NORTH_STAR_LASTDB_GIT_FORGE_SOURCE_DIR:-${FOLD_REPO:-}}"
if [ -z "$SOURCE_ROOT" ]; then
  SOURCE_ROOT="$(ns_repo_path lastdb)"
fi
refuse_primary "$SOURCE_ROOT"

HANDLERS="$SOURCE_ROOT/$HANDLERS_REL"
REQUEST="$SOURCE_ROOT/$REQUEST_REL"
AUTH="$SOURCE_ROOT/$AUTH_REL"
AUTH_TESTS="$SOURCE_ROOT/$AUTH_TESTS_REL"
for file in "$HANDLERS" "$REQUEST" "$AUTH" "$AUTH_TESTS"; do
  refuse_primary "$file"
  [ -f "$file" ] || finish FAIL "The Fold source is absent: ${file#"$SOURCE_ROOT"/}."
done

# Request and wire shape: a grant must carry the complete content-addressed set
# from the Fold client to the storage service.
require_text "$REQUEST" "pub(crate) guaranteed_blob_ids: Vec<String>" \
  "the guaranteed blob request field"
require_text "$AUTH" 'pub blob_ids: Vec<String>' \
  "the guaranteed blob pointer field"
require_text "$AUTH" '#[serde(default)]' \
  "backward-compatible blob pointer decoding"
require_text "$AUTH" '"guaranteed_blob_ids": candidate.blob_ids' \
  "the guaranteed blob client payload"

# Validation: the service must bound, canonicalize, deduplicate, and scope blob
# IDs before it can build a storage key or advance a grant.
require_text "$HANDLERS" 'fn guaranteed_write_blob_key(scope: &str, blob_id: &str)' \
  "the scoped blob key helper"
require_text "$HANDLERS" 'fn guaranteed_write_blob_ids_from_request(body: &RequestBody)' \
  "the guaranteed blob request validator"
require_text "$HANDLERS" 'guaranteed_blob_ids must name at most 64 blobs' \
  "the blob count limit"
require_text "$HANDLERS" 'guaranteed_blob_ids must not name a blob more than once' \
  "the duplicate blob refusal"
require_text "$HANDLERS" 'let blob_ids = guaranteed_write_blob_ids_from_request(body)?;' \
  "the pointer validation call"
require_text "$HANDLERS" 'blob_ids,' \
  "the blob set persisted in the pointer"

# Commit gate: every named blob gets a scoped HEAD check before the existing
# pointer read/CAS path. A missing object is a validation failure, not a grant.
require_text "$HANDLERS" 'async fn ensure_guaranteed_write_blobs_exist(' \
  "the blob existence gate"
require_text "$HANDLERS" 'head_object().bucket(bucket).key(&key).send().await' \
  "the per-blob storage HEAD"
require_text "$HANDLERS" 'Err(error) if is_not_found_error(&error)' \
  "the missing-blob branch"
require_text "$HANDLERS" 'guaranteed write blob is missing: {blob_id}' \
  "the missing-blob validation error"
require_text "$HANDLERS" 'candidate.blob_ids' \
  "the candidate blob set passed to the gate"
require_order_after "$HANDLERS" \
  'async fn handle_guaranteed_write_cas(' \
  'ensure_guaranteed_write_blobs_exist(client' \
  'let current = match read_guaranteed_write' \
  "blob validation before pointer read"
require_order_after "$HANDLERS" \
  'async fn handle_guaranteed_write_cas(' \
  'ensure_guaranteed_write_blobs_exist(client' \
  'let mut put = client' \
  "blob validation before pointer write"
require_text "$HANDLERS" 'stored.pointer.blob_ids == candidate.blob_ids' \
  "retry identity including the blob set"

# Keep the proof tied to the real product tests that exercise the request
# shape and duplicate refusal. These names are stable contract anchors.
require_text "$HANDLERS" \
  'fn guaranteed_write_rejects_duplicate_blob_ids_before_cloud_access()' \
  "the duplicate refusal unit test"
require_text "$HANDLERS" \
  'fn guaranteed_write_is_scoped_and_rejects_unsafe_key_parts()' \
  "the scoped key unit test"
require_text "$AUTH_TESTS" \
  'async fn two_ephemeral_nodes_share_one_org_guaranteed_write_slot()' \
  "the two-node guaranteed-write test"

source_label="source=${SOURCE_ROOT}"
if source_oid="$(git -C "$SOURCE_ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
  source_label="${source_label} oid=${source_oid}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
  body="Fold guaranteed-write blob contract: FAIL

${source_label}

Source failures:
"
  for failure in "${FAILURES[@]}"; do
    body="${body}- ${failure}
"
  done
  finish FAIL "$body"
fi

finish PASS-OFFLINE "$(cat <<EOF
Fold guaranteed-write blob contract: PASS-OFFLINE

${source_label}

The offline proof checks the merged product contract:

- the client and pointer carry the complete content-addressed blob set;
- the storage service validates count, duplicates, safe scoped keys, and blob presence;
- every blob receives a storage HEAD check before the pointer read or CAS write;
- a missing blob returns a validation error and a retry compares the blob set;
- the Fold source contains the scoped-key, duplicate-refusal, and two-node tests.

No LastDB home, socket, cloud service, or shared infrastructure was opened.
EOF
)"
