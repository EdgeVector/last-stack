#!/usr/bin/env bash
# Live mode of the delete-returns-bytes proof, without a real node.
#
# The measurement is the whole point of live mode, so the assertions have to be
# testable without paying a 22 GiB CoW clone in CI. A stub `lastdb` on PATH
# replays a scripted compact report per (collection, phase), which pins the
# thing that can actually rot: which numbers the harness reads, and which
# combinations it refuses to call a PASS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
SLUG=north-star-lastdb-delete-returns-the-bytes
WORK="$(mktemp -d "${TMPDIR:-/tmp}/delete-returns-bytes-live-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-delete-returns-bytes-live: $*" >&2
  exit 1
}

# --- a fold tree whose structural gates all pass --------------------------
fold="$WORK/fold"
mkdir -p \
  "$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/molecules" \
  "$fold/fold_db/crates/core/src/fold_db_core/purge" \
  "$fold/fold_db/crates/core/src/storage/laststore" \
  "$fold/fold_db/crates/core/tests" \
  "$fold/vendor/laststore/src"
echo 'fn prepare_delete() {}' \
  >"$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/molecules/prepare.rs"
echo 'fn index_purge() { emit(IndexChangeKind::Tombstone); }' \
  >"$fold/fold_db/crates/core/src/fold_db_core/mutation_manager/index.rs"
echo 'fn purge() { record(search_index.delete()); }' \
  >"$fold/fold_db/crates/core/src/fold_db_core/purge/mod.rs"
echo 'fn purge_delivers_tombstone_to_index_sink() {}' \
  >"$fold/fold_db/crates/core/tests/purge_index.rs"
cat >"$fold/fold_db/crates/core/src/storage/laststore/mod.rs" <<'EOF'
pub const COMPACT_ALLOWLIST: &[&str] = &[
    "tips",
    "atoms",
];
fn compact_collection_admin() { store.compact_atoms_with_retirement_provenance(); }
EOF
cat >"$fold/vendor/laststore/src/options.rs" <<'EOF'
const ATOMS_COLLECTION: &str = "atoms";
fn default_options() {
    collection_policies.insert(
        ATOMS_COLLECTION.to_string(),
        CollectionPolicy {
            never_compact: true,
        },
    );
}
EOF
cat >"$fold/fold_db/crates/core/src/storage/laststore/backup_manifest.rs" <<'EOF'
fn cut() { BackupDeletionReceipt::new_purged_atom_retirement(); }
fn reject() { fail("rollback/truncation attack suspected"); }
EOF

# --- stub lastdb: replays $STUB_DIR/<collection>.<phase>.json -------------
stub_bin="$WORK/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/lastdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
coll=""
execute=0
prev=""
for a in "$@"; do
  case "$prev" in --collection) coll="$a" ;; esac
  [ "$a" = "--execute" ] && execute=1
  prev="$a"
done
[ -n "$coll" ] || { echo "stub lastdb: no --collection" >&2; exit 2; }
if [ "$execute" -eq 1 ]; then
  phase=exec
else
  n="$STUB_DIR/$coll.dry.count"
  seen=0
  [ -f "$n" ] && seen="$(cat "$n")"
  seen=$((seen + 1))
  printf '%s\n' "$seen" >"$n"
  phase="dry$seen"
fi
out="$STUB_DIR/$coll.$phase.json"
[ -f "$out" ] || { echo "stub lastdb: no scripted report for $coll.$phase" >&2; exit 1; }
printf '%s\n' "$STUB_DIR/$coll.$phase" >>"$STUB_DIR/calls.log"
cat "$out"
EOF
chmod +x "$stub_bin/lastdb"

plane_json() {
  # plane_json <collection> <bytes_before> <bytes_after|null> <residue_unknown> <executed>
  printf '{"collection":"%s","live_keys":10,"bytes_before":%s,"bytes_after":%s,' "$1" "$2" "$3"
  printf '"dead_bytes":4096,"live_bytes":8192,"residue_unknown_bytes":%s,"executed":%s}\n' "$4" "$5"
}

# A node home whose socket is NOT under $HOME/.lastdb.
node_home="$WORK/node"
mkdir -p "$node_home/data"
sock="$node_home/data/folddb.sock"

run_live() {
  # run_live <stub-dir> <proof-dir> <socket>
  STUB_DIR="$1" PATH="$stub_bin:$PATH" HOME="$WORK/home" \
    FOLD_REPO="$fold" NORTH_STAR_PROOF_DIR="$2" NORTH_STAR_PROOF_SOCKET="$3" \
    "$RUNNER" --live "$SLUG"
}
mkdir -p "$WORK/home"

# --- 1. both planes shrink and account for every byte -> PASS ------------
good="$WORK/stub-good"
mkdir -p "$good"
for coll in atoms tips; do
  plane_json "$coll" 900000 900000 4096 false >"$good/$coll.dry1.json"
  plane_json "$coll" 900000 500000 0 true    >"$good/$coll.exec.json"
  plane_json "$coll" 500000 500000 0 false   >"$good/$coll.dry2.json"
done
run_live "$good" "$WORK/pass" "$sock" >"$WORK/pass.out" 2>&1 \
  || fail "live mode failed on a store where both planes shrank: $(cat "$WORK/pass.out")"
report="$WORK/pass/$SLUG.md"
test "$(sed -n '1p' "$report")" = PASS \
  || fail "live verdict was not PASS: $(sed -n '1p' "$report")"
grep -q 'live/atoms: bytes_before=900000 -> bytes_after=500000 reclaimed=400000' "$report" \
  || fail "the atoms byte delta is not in the report"
grep -q 'live/tips: bytes_before=900000 -> bytes_after=500000 reclaimed=400000' "$report" \
  || fail "the tips byte delta is not in the report"
grep -q 'live/atoms: residue_unknown_bytes=0 after compact' "$report" \
  || fail "the post-compact residue check is not in the report"
grep -q 'live/atoms: dry-run bytes_before=900000 dead_bytes=4096' "$report" \
  || fail "the pre-compact dry-run numbers are not in the report"

# --- 2. a plane that did not shrink is not a proof -----------------------
flat="$WORK/stub-flat"
mkdir -p "$flat"
for coll in atoms tips; do
  plane_json "$coll" 900000 900000 4096 false >"$flat/$coll.dry1.json"
  plane_json "$coll" 900000 900000 0 true     >"$flat/$coll.exec.json"
  plane_json "$coll" 900000 900000 0 false    >"$flat/$coll.dry2.json"
done
if run_live "$flat" "$WORK/flat" "$sock" >"$WORK/flat.out" 2>&1; then
  fail "live mode passed although no plane returned a byte"
fi
grep -q 'live/atoms: FAIL — bytes_after=900000 is not below bytes_before=900000' "$WORK/flat/$SLUG.md" \
  || fail "the no-shrink failure did not name the byte counts"

# --- 3. leftover unmeasured residue is not a proof -----------------------
residue="$WORK/stub-residue"
mkdir -p "$residue"
for coll in atoms tips; do
  plane_json "$coll" 900000 900000 4096 false >"$residue/$coll.dry1.json"
  plane_json "$coll" 900000 500000 0 true     >"$residue/$coll.exec.json"
  plane_json "$coll" 500000 500000 77 false   >"$residue/$coll.dry2.json"
done
if run_live "$residue" "$WORK/residue" "$sock" >"$WORK/residue.out" 2>&1; then
  fail "live mode passed although bytes were left unaccounted for"
fi
grep -q 'live/atoms: FAIL — residue_unknown_bytes=77 after compact' "$WORK/residue/$SLUG.md" \
  || fail "the residue failure did not name the unmeasured bytes"

# --- 4. the primary brain is refused before any byte is read -------------
primary_home="$WORK/home/.lastdb"
mkdir -p "$primary_home/data"
refuse="$WORK/stub-refuse"
mkdir -p "$refuse"
if run_live "$refuse" "$WORK/refuse" "$primary_home/data/folddb.sock" \
    >"$WORK/refuse.out" 2>&1; then
  fail "live mode ran against the primary brain socket"
fi
grep -q 'live: refused' "$WORK/refuse/$SLUG.md" \
  || fail "the primary refusal is not in the report"
test ! -f "$refuse/calls.log" \
  || fail "the harness called lastdb after refusing the primary socket"

# --- 5. no socket and no autoboot is a named failure, not a silent skip ---
noboot="$WORK/stub-noboot"
mkdir -p "$noboot"
if STUB_DIR="$noboot" PATH="$stub_bin:$PATH" HOME="$WORK/home" \
    FOLD_REPO="$fold" NORTH_STAR_PROOF_DIR="$WORK/noboot" \
    NORTH_STAR_PROOF_LIVE_AUTOBOOT=0 \
    "$RUNNER" --live "$SLUG" >"$WORK/noboot.out" 2>&1; then
  fail "live mode passed with no node to measure"
fi
grep -q 'live: NORTH_STAR_PROOF_SOCKET unset and autoboot disabled' "$WORK/noboot/$SLUG.md" \
  || fail "the missing-socket failure did not name the autoboot switch"

echo "PASS last-stack-north-star-proof-delete-returns-bytes-live"
