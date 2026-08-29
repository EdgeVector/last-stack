#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
SLUG=north-star-lastdb-delete-returns-the-bytes
WORK="$(mktemp -d "${TMPDIR:-/tmp}/delete-returns-bytes-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-delete-returns-bytes: $*" >&2
  exit 1
}

fold="$WORK/fold"
mkdir -p \
  "$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/molecules" \
  "$fold/fold_db/crates/core/src/fold_db_core/mutation_manager" \
  "$fold/fold_db/crates/core/src/fold_db_core/purge" \
  "$fold/fold_db/crates/core/src/storage/laststore" \
  "$fold/fold_db/crates/core/tests" \
  "$fold/vendor/laststore/src"

cat >"$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/molecules/prepare.rs" <<'EOF'
fn prepare_delete() {}
EOF
cat >"$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/index.rs" <<'EOF'
fn index_purge() { let kind = IndexChangeKind::Tombstone; emit(kind); }
EOF
cat >"$fold/fold_db/crates/core/src/fold_db_core/purge/mod.rs" <<'EOF'
fn purge() { let embedding_rows_deleted = search_index.delete(); record(embedding_rows_deleted); }
EOF
cat >"$fold/fold_db/crates/core/tests/purge_index.rs" <<'EOF'
fn purge_delivers_tombstone_to_index_sink() {}
EOF
cat >"$fold/fold_db/crates/core/src/storage/laststore/mod.rs" <<'EOF'
// An earlier COMPACT_ALLOWLIST comment mentions "tips" but is not the value.
pub const COMPACT_ALLOWLIST: &[&str] = &[
    "schemas",
    "tips",
    "atoms",
];

fn compact_collection_admin(store: &Store, collection: &str) {
    if collection == "atoms" {
        store.compact_atoms_with_retirement_provenance();
    }
}
EOF
cat >"$fold/vendor/laststore/src/options.rs" <<'EOF'
const ATOMS_COLLECTION: &str = "atoms";
fn default_options() {
    collection_policies.insert(
        ATOMS_COLLECTION.to_string(),
        CollectionPolicy {
            never_compact: true,
            backup_excluded: false,
        },
    );
}
EOF
cat >"$fold/fold_db/crates/core/src/storage/laststore/backup_manifest.rs" <<'EOF'
fn cut_manifest() { BackupDeletionReceipt::new_purged_atom_retirement(); }
fn reject_unreceipted_shrink() { fail("rollback/truncation attack suspected"); }
EOF

run_proof() {
  local proof_dir="$1"
  FOLD_REPO="$fold" NORTH_STAR_PROOF_DIR="$proof_dir" \
    "$RUNNER" --offline "$SLUG"
}

run_proof "$WORK/pass-reports" >"$WORK/pass.out"
report="$WORK/pass-reports/$SLUG.md"
test "$(sed -n '1p' "$report")" = PASS-OFFLINE || fail "current Fold source shape did not pass"
grep -q 'D1: tips is in the declared COMPACT_ALLOWLIST value' "$report" \
  || fail "D1 did not report the scoped allowlist contract"
grep -q 'D3a: ordinary atom compaction stays disabled' "$report" \
  || fail "D3 did not preserve the ordinary never_compact guard"
grep -q 'D3c: the atom owner path records retirement provenance' "$report" \
  || fail "D3 did not report the provenance compact path"
grep -q 'D3e: unreceipted atom keep-set shrink remains refused' "$report" \
  || fail "D3 did not report the unreceipted-shrink refusal"

laststore_mod="$fold/fold_db/crates/core/src/storage/laststore/mod.rs"
cp "$laststore_mod" "$WORK/laststore-mod.good"
sed '/^[[:space:]]*"tips",[[:space:]]*$/d' "$WORK/laststore-mod.good" >"$laststore_mod"
if run_proof "$WORK/no-tips-reports" >"$WORK/no-tips.out" 2>&1; then
  fail "D1 accepted a comment match after the declared tips entry was removed"
fi
grep -q 'D1: FAIL — tips is not on COMPACT_ALLOWLIST' "$WORK/no-tips-reports/$SLUG.md" \
  || fail "D1 failure did not name the missing declared tips entry"

cp "$WORK/laststore-mod.good" "$laststore_mod"
sed 's/compact_atoms_with_retirement_provenance/compact_atoms/' \
  "$WORK/laststore-mod.good" >"$laststore_mod"
if run_proof "$WORK/no-provenance-reports" >"$WORK/no-provenance.out" 2>&1; then
  fail "D3 accepted an atom compact path without retirement provenance"
fi
grep -q 'D3c: FAIL — the atom owner path does not call compact_atoms_with_retirement_provenance' \
  "$WORK/no-provenance-reports/$SLUG.md" \
  || fail "D3 failure did not name the missing provenance compact call"

echo "PASS last-stack-north-star-proof-delete-returns-bytes"
