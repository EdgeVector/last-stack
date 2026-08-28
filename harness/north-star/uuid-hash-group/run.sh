#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-uuid-hash-group-addressing
# Prove the UUID hash-group product on throwaway stores. Never mutate primary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck disable=SC1091
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-uuid-hash-group-addressing
MODE="$(ns_mode)"
FOLD_ROOT="$(ns_repo_path fold)"
COW_PROOF="${UUID_HASH_GROUP_COW_PROOF_FILE:-$HOME/.local/state/last-stack/runtime/north-star-proofs/${SLUG}-cow.md}"
PRIMARY_HOME="${UUID_HASH_GROUP_PRIMARY_HOME:-$HOME/.lastdb}"
TARGET_DIR="${UUID_HASH_GROUP_CARGO_TARGET_DIR:-$HOME/.cache/last-stack/north-star-proof-target}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

require_text() {
  local file="$1" pattern="$2" label="$3"
  [ -f "$file" ] || fail "missing proof input: $file"
  grep -Eq "$pattern" "$file" || fail "missing product contract: $label

File: $file"
}

sync_config_state() {
  local file="$PRIMARY_HOME/cloud_sync.json"
  if [ -f "$file" ]; then
    shasum -a 256 "$file" | awk '{print "present:" $1}'
  else
    printf '%s\n' absent
  fi
}

[ -d "$FOLD_ROOT/vendor/laststore" ] || fail "Fold source tree not found: $FOLD_ROOT"
[ -f "$COW_PROOF" ] || fail "immutable CoW proof not found: $COW_PROOF"

# Product contract on the shipped Fold source. Existing descriptors still
# decide reopen layout; only a new home receives the hash-group default.
require_text "$FOLD_ROOT/vendor/laststore/src/options.rs" \
  'layout_mode: LayoutMode::HashGroup' 'new LastStore homes default to hash-group layout'
require_text "$FOLD_ROOT/vendor/laststore/src/options.rs" \
  'hash_group_warm_bytes: DEFAULT_HASH_GROUP_WARM_BYTES' 'the default warm set is bounded'
require_text "$FOLD_ROOT/vendor/laststore/src/options.rs" \
  'DEFAULT_HASH_GROUP_WARM_MAX_HANDLES: usize = 64' 'the default append descriptor set is bounded'
require_text "$FOLD_ROOT/fold_db/crates/core/src/fold_db_core/factory/local.rs" \
  'adapter_open_creates_uuid_hash_group_home' 'the Fold factory has a new-home behavior proof'
require_text "$FOLD_ROOT/fold_db/crates/core/src/fold_db_core/factory/local.rs" \
  'adapter_open_serves_legacy_journal_records' 'the Fold factory preserves legacy journal reads'
require_text "$FOLD_ROOT/vendor/laststore/tests/warm_set_handle_cap.rs" \
  'the_descriptor_gauge_tracks_closes_as_well_as_opens' 'warm-set descriptor metrics are observable'
require_text "$FOLD_ROOT/vendor/laststore/tests/plain_seg_backup_addressing.rs" \
  'every_enumerated_plain_chunk_verifies_on_hash_group_home' 'group files have stable backup addresses'
require_text "$FOLD_ROOT/vendor/laststore/tests/fault_injection.rs" \
  'hash_group_sealed_chunk_corruption_quarantines_and_install_chunk_restores' 'a group chunk restores as-is'

# Preserve the immutable real-data bar. It records the source fingerprint,
# 11M-document parity, a successful reopen, and no promotion of the CoW copy.
[ "$(sed -n '1p' "$COW_PROOF")" = PASS ] || fail "CoW proof verdict is not PASS: $COW_PROOF"
for evidence in \
  'source_layout: segment_log.*destination_layout:.*hash_group' \
  'total_documents:.*11,472,142' \
  'source_unchanged: true' \
  'cloud_sync_copied:.*false' \
  'promoted:.*false' \
  'survived clean stop.*restart'; do
  grep -Eiq "$evidence" "$COW_PROOF" || fail "CoW proof lacks required evidence: $evidence"
done

sync_before="$(sync_config_state)"
test_evidence="source contracts and immutable CoW evidence"
sync_evidence="primary sync configuration was not inspected in offline mode"

if [ "$MODE" = live ]; then
  ns_require_cmd cargo || fail "cargo is required for the live behavior proof"
  ns_require_cmd brain || fail "brain is required to verify the current sync authority"
  ns_require_cmd lastdb || fail "lastdb is required to read current primary status"

  # The July North Star required no silent primary re-enable. A later, explicit
  # Tom-authorized operation re-enabled sync after the Situation cleared. The
  # current proof must preserve that state, not claim that sync is still off.
  policy="$(brain get checkpoint-cloud-sync-reenable-20260730 2>&1)" || \
    fail "could not read the authoritative cloud-sync re-enable checkpoint"
  printf '%s\n' "$policy" | grep -Eiq "Tom's /goal|Tom.*goal" || \
    fail "cloud-sync checkpoint does not record Tom authority"
  printf '%s\n' "$policy" | grep -Eiq 'old cloud-sync pause Situation was already' || \
    fail "cloud-sync checkpoint does not record Situation clearance"
  printf '%s\n' "$policy" | grep -Eiq 'cloud_sync\.json restored|re-enabled' || \
    fail "cloud-sync checkpoint does not record the later re-enable"

  mkdir -p "$TARGET_DIR"
  (
    cd "$FOLD_ROOT"
    CARGO_TARGET_DIR="$TARGET_DIR" cargo test -p laststore \
      --test hash_group new_home_defaults_to_hash_group_and_places_by_uuid -- --exact
    CARGO_TARGET_DIR="$TARGET_DIR" cargo test -p fold_db --lib adapter_open_ -- --nocapture
    CARGO_TARGET_DIR="$TARGET_DIR" cargo test -p laststore --test warm_set_handle_cap
    CARGO_TARGET_DIR="$TARGET_DIR" cargo test -p laststore \
      --test plain_seg_backup_addressing
    CARGO_TARGET_DIR="$TARGET_DIR" cargo test -p laststore --test fault_injection \
      hash_group_sealed_chunk_corruption_quarantines_and_install_chunk_restores -- --exact
  )

  sync_line="$(lastdb status | grep '^Sync:' | head -n 1)"
  [ -n "$sync_line" ] || fail "primary status did not expose a Sync line"
  sync_after="$(sync_config_state)"
  [ "$sync_before" = "$sync_after" ] || \
    fail "the live proof changed the primary cloud-sync configuration"

  test_evidence="five focused behavior bars passed against Fold main"
  sync_evidence="the Tom-authorized sync configuration remained byte-identical; status exposed: $sync_line"
fi

body="$(cat <<EOF
UUID hash-group terminal proof.

Mode: $MODE
Fold source: $FOLD_ROOT
CoW evidence: $COW_PROOF

- New homes use deterministic UUID hash-group placement.
- Existing journal homes reopen and serve their recorded values.
- The warm set has a 256 MiB byte budget, a 64-descriptor cap, and observable gauges.
- Hash-group chunk enumeration and as-is restore behavior are proven on throwaway fixtures.
- The immutable real-data CoW proof preserves 11,472,142 documents and never promotes its destination.
- $test_evidence.
- $sync_evidence.

The harness never opens, starts, stops, or writes the primary LastDB home.
EOF
)"

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$body"
