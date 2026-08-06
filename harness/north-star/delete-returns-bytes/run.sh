#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-delete-returns-the-bytes
# Terminal proof for "deleting a record erases it and returns the bytes".
#
# Offline (default, CI-safe): structural gates read from the fold source tree.
# Each gate corresponds to one END STATE condition and flips from FAIL to PASS
# exactly when that slice lands, so an in-flight North Star reports FAIL for a
# named reason rather than being silently treated as not-required.
#
# Live (NORTH_STAR_PROOF_MODE=live): the byte measurement, on a copy-on-write
# clone of a LastDB home reached through an isolated socket. NEVER the primary
# brain — ns_refuse_primary is called before any socket is used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-delete-returns-the-bytes
MODE="$(ns_mode)"

notes=()
append() { notes+=("$1"); }

FOLD="$(ns_repo_path fold)"

require_fold_tree() {
  if [ ! -d "$FOLD/fold_db/crates/core/src" ]; then
    append "fold source tree not resolvable at $FOLD — cannot evaluate structural gates"
    return 1
  fi
  append "fold source tree resolved at $FOLD"
  return 0
}

# --- Gate A: a delete writes one row, not one per field -------------------
# Slice A routes MutationType::Delete through the purge path. Until it lands,
# molecules/prepare.rs synthesizes a tombstone atom for EVERY field of the
# schema, so an N-field delete costs N atoms + N order-log entries.
check_delete_is_single_write() {
  local prepare="$FOLD/fold_db/crates/core/src/fold_db_core/mutation_manager/molecules/prepare.rs"
  if [ ! -f "$prepare" ]; then
    append "A: prepare.rs not found at expected path"
    return 1
  fi
  if grep -q 'build_delete_tombstone_fields' "$prepare"; then
    append "A: FAIL — delete still synthesizes a tombstone atom per field (build_delete_tombstone_fields in prepare.rs)"
    return 1
  fi
  append "A: per-field tombstone synthesis is gone from the delete path"
  return 0
}

# --- Gate B: a deleted record leaves every read surface -------------------
# Purge emitted no index change (`MutationType::Purge => continue`), so a
# purged record stayed searchable. Latent while purge was a rare admin verb;
# user-visible the moment delete routes through it.
check_purge_updates_search_index() {
  local index="$FOLD/fold_db/crates/core/src/fold_db_core/mutation_manager/index.rs"
  if [ ! -f "$index" ]; then
    append "B: index.rs not found at expected path"
    return 1
  fi
  if grep -qE 'MutationType::Purge\s*=>\s*continue' "$index"; then
    append "B: FAIL — Purge still emits no search-index change (MutationType::Purge => continue)"
    return 1
  fi
  append "B: Purge emits a search-index change"
  return 0
}

# --- Gate B2: the compliance ledger stops reporting an unmeasured zero -----
check_embedding_ledger_is_honest() {
  local purge="$FOLD/fold_db/crates/core/src/fold_db_core/purge/mod.rs"
  if [ ! -f "$purge" ]; then
    append "B2: purge/mod.rs not found at expected path"
    return 1
  fi
  if grep -qE 'let embedding_rows_deleted = 0usize;' "$purge"; then
    append "B2: FAIL — embedding_rows_deleted is still a hardcoded 0 written into the delete ledger"
    return 1
  fi
  append "B2: embedding_rows_deleted is no longer a hardcoded constant"
  return 0
}

# --- Gate D1: the tips plane is compactable -------------------------------
check_tips_compactable() {
  local ls_mod="$FOLD/fold_db/crates/core/src/storage/laststore/mod.rs"
  if [ ! -f "$ls_mod" ]; then
    append "D1: storage/laststore/mod.rs not found at expected path"
    return 1
  fi
  if ! grep -A3 'COMPACT_ALLOWLIST' "$ls_mod" | grep -q '"tips"'; then
    append "D1: FAIL — tips is not on COMPACT_ALLOWLIST; the largest plane cannot be compacted"
    return 1
  fi
  append "D1: tips is on the compaction allowlist"
  return 0
}

# --- Gate D2: atoms retire on purge, and only with a receipt ---------------
# The receipt mechanism already exists (BackupDeletionReceipt, two record
# types, and a chain validation that refuses an unexplained keep-set shrink).
# What is missing is a PURGE-driven retirement: today the only atom retirement
# is `unbackable_atom_chunk_retirement_receipt`, which is system-authorized and
# fires only for atoms proven absent from BOTH local disk and cloud — it
# deliberately KEEPS anything still in the object store, because that copy may
# be the only restore path. A record the user deleted on purpose needs a
# user-authorized retirement instead.
#
# Do not gate on the prose "deletion receipt": it appears in comments that
# predate this North Star, so a prose grep reports a false PASS.
check_atoms_retire_on_purge() {
  local manifest="$FOLD/fold_db/crates/core/src/storage/laststore/backup_manifest.rs"
  if [ ! -f "$manifest" ]; then
    append "D2: backup_manifest.rs not found at expected path"
    return 1
  fi
  local ok=0
  if grep -q 'new_purged_atom_retirement' "$manifest"; then
    append "D2a: user-authorized purge-driven atom retirement exists"
  else
    append "D2a: FAIL — no purge-driven atom retirement; only unbackable (absent-everywhere) atoms can leave the keep-set, so a deliberately deleted record keeps being billed"
    ok=1
  fi
  if grep -q 'rollback/truncation attack suspected' "$manifest"; then
    append "D2b: receipt-less atom-list truncation is still refused"
  else
    append "D2b: FAIL — the truncation refusal is gone; the tamper defense was weakened rather than explained"
    ok=1
  fi
  return "$ok"
}

# --- Gate D3: the atoms plane can actually be compacted locally ------------
# `atoms` defaults to never_compact: true in laststore options — write-once
# backup material. Local bytes cannot return until that is lifted (gated on the
# receipt path above, never independently of it).
check_atoms_compactable() {
  local opts="$FOLD/vendor/laststore/src/options.rs"
  if [ ! -f "$opts" ]; then
    append "D3: vendor/laststore/src/options.rs not found at expected path"
    return 1
  fi
  if grep -A4 'ATOMS_COLLECTION.to_string()' "$opts" | grep -qE 'never_compact:\s*true'; then
    append "D3: FAIL — atoms is still unconditionally never_compact; local atom bytes cannot return"
    return 1
  fi
  append "D3: the atoms never_compact default is no longer unconditional"
  return 0
}

# --- Live mode: the byte measurement --------------------------------------
# Requires an isolated LastDB home + socket supplied by the caller. Refuses the
# primary outright rather than trusting the caller to have pointed elsewhere.
run_live_measurement() {
  local sock="${NORTH_STAR_PROOF_SOCKET:-}"
  if [ -z "$sock" ]; then
    append "live: NORTH_STAR_PROOF_SOCKET unset — a CoW clone on an isolated socket is required"
    return 1
  fi
  if ! ns_refuse_primary "$sock"; then
    append "live: refused — $sock is the primary brain"
    return 1
  fi
  if ! ns_require_cmd lastdb; then
    append "live: lastdb CLI missing"
    return 1
  fi
  append "live: measurement against isolated socket $sock"
  append "live: byte measurement is owned by the slice-D card and is not yet implemented here"
  return 1
}

ok=0
require_fold_tree || ok=1
if [ "$ok" -eq 0 ]; then
  check_delete_is_single_write   || ok=1
  check_purge_updates_search_index || ok=1
  check_embedding_ledger_is_honest || ok=1
  check_tips_compactable         || ok=1
  check_atoms_retire_on_purge    || ok=1
  check_atoms_compactable        || ok=1
fi

if [ "$MODE" = "live" ] && [ "$ok" -eq 0 ]; then
  run_live_measurement || ok=1
fi

body=""
for n in "${notes[@]}"; do
  body="${body}- ${n}"$'\n'
done
body="${body}"$'\n'"Mode: ${MODE}. Structural gates read from the fold source tree; the live byte measurement runs only against an isolated CoW clone, never the primary brain."

if [ "$ok" -eq 0 ]; then
  if [ "$MODE" = "live" ]; then
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
else
  ns_write_report "$SLUG" FAIL "$body"
fi
