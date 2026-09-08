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
#
# This reaches past LastDB's own index. The Search app (lastdb:///search) keeps
# its own FastEmbed vector plane and already drops a vector on
# IndexChangeKind::Tombstone (src/vector/plane.ts applyBatch -> removeByKey).
# The consumer is correct; the producer is the break. Land slice A without this
# and a deleted record's embedding survives in another app's store and keeps
# being returned by semantic recall with nothing left to hydrate it from —
# strictly worse than today, which is why B gates A rather than sitting beside it.
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

# --- Gate B3: purge's tombstone DELIVERY is asserted, not just its code path -
# Removing the `continue` makes gate B green while proving nothing about what
# reaches the sink. The Search app is a separate process holding a derived copy
# of deleted content, so the claim that has to hold is delivery: a Purge
# mutation produces an IndexChangeKind::Tombstone on the index sink for that
# key. Gate on a named test so the assertion cannot quietly disappear.
check_purge_tombstone_delivery_tested() {
  local core="$FOLD/fold_db/crates/core"
  if [ ! -d "$core" ]; then
    append "B3: fold_db/crates/core not found at expected path"
    return 1
  fi
  if ! grep -rq 'purge_delivers_tombstone_to_index_sink' "$core" 2>/dev/null; then
    append "B3: FAIL — no test asserts a Purge delivers IndexChangeKind::Tombstone to the index sink; the Search app's vector plane has no proof it is told"
    return 1
  fi
  append "B3: purge->tombstone delivery to the index sink is asserted by a named test"
  return 0
}

# --- Gate D1: the tips plane is compactable -------------------------------
compact_allowlist_block() {
  local source="$1"
  sed -n '/^[[:space:]]*pub const COMPACT_ALLOWLIST:/,/^[[:space:]]*];/p' "$source"
}

check_tips_compactable() {
  local ls_mod="$FOLD/fold_db/crates/core/src/storage/laststore/mod.rs"
  if [ ! -f "$ls_mod" ]; then
    append "D1: storage/laststore/mod.rs not found at expected path"
    return 1
  fi
  local allowlist
  allowlist="$(compact_allowlist_block "$ls_mod")"
  if [ -z "$allowlist" ] || ! grep -qE '^[[:space:]]*"tips",[[:space:]]*$' <<<"$allowlist"; then
    append "D1: FAIL — tips is not on COMPACT_ALLOWLIST; the largest plane cannot be compacted"
    return 1
  fi
  append "D1: tips is in the declared COMPACT_ALLOWLIST value"
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

# --- Gate D3: atom compact uses the receipt-backed owner path ---------------
# Ordinary LastStore compaction must keep `atoms.never_compact = true`. The
# owner admin path is the exception: atoms must be on the Fold allowlist, and
# that path must compact only after it records retirement provenance. The
# manifest must accept the named purge receipt and still reject any unexplained
# keep-set shrink.
check_atoms_compactable() {
  local ls_mod="$FOLD/fold_db/crates/core/src/storage/laststore/mod.rs"
  local opts="$FOLD/vendor/laststore/src/options.rs"
  local manifest="$FOLD/fold_db/crates/core/src/storage/laststore/backup_manifest.rs"
  if [ ! -f "$ls_mod" ] || [ ! -f "$opts" ] || [ ! -f "$manifest" ]; then
    append "D3: receipt-gated atom compact sources are not all present at the expected paths"
    return 1
  fi

  local ok=0 allowlist atom_policy
  allowlist="$(compact_allowlist_block "$ls_mod")"
  atom_policy="$(sed -n '/ATOMS_COLLECTION.to_string()/,/^[[:space:]]*);/p' "$opts")"

  if [ -z "$atom_policy" ] || ! grep -qE 'never_compact:[[:space:]]*true' <<<"$atom_policy"; then
    append "D3a: FAIL — ordinary atom compaction is not protected by atoms.never_compact"
    ok=1
  else
    append "D3a: ordinary atom compaction stays disabled by atoms.never_compact"
  fi
  if [ -z "$allowlist" ] || ! grep -qE '^[[:space:]]*"atoms",[[:space:]]*$' <<<"$allowlist"; then
    append "D3b: FAIL — atoms is not in the declared COMPACT_ALLOWLIST value"
    ok=1
  else
    append "D3b: the owner compact allowlist admits atoms"
  fi
  if ! grep -q 'compact_atoms_with_retirement_provenance' "$ls_mod"; then
    append "D3c: FAIL — the atom owner path does not call compact_atoms_with_retirement_provenance"
    ok=1
  else
    append "D3c: the atom owner path records retirement provenance before compact"
  fi
  if ! grep -q 'new_purged_atom_retirement' "$manifest"; then
    append "D3d: FAIL — the manifest does not carry the purge retirement receipt"
    ok=1
  else
    append "D3d: the manifest carries the named purge retirement receipt"
  fi
  if ! grep -q 'rollback/truncation attack suspected' "$manifest"; then
    append "D3e: FAIL — unreceipted atom keep-set shrink is not refused"
    ok=1
  else
    append "D3e: unreceipted atom keep-set shrink remains refused"
  fi
  return "$ok"
}

# --- Live mode: the byte measurement --------------------------------------
# The structural gates above read source. This one reads bytes off a real
# store: compact `atoms` and `tips` and require that the plane got smaller and
# that nothing is left unaccounted for. It runs against an isolated CoW clone
# reached through its own socket, never the primary brain.
#
# Socket resolution, in order:
#   1. NORTH_STAR_PROOF_SOCKET  — the caller owns the node's lifecycle.
#   2. autoboot                 — this harness starts a PRIVATE `lastdb-dev`
#      node on its own home/state and stops it again. The shared ~/.lastdb-dev
#      is deliberately not reused: other agents run their inner loop there, and
#      an --execute compact underneath them is not ours to spend.
# Either way ns_refuse_primary runs before a single byte is read.

NS_LIVE_DEV_STARTED=0
NS_LIVE_DEV_HOME=""
NS_LIVE_DEV_STATE=""

ns_live_dev_stop() {
  [ "$NS_LIVE_DEV_STARTED" -eq 1 ] || return 0
  NS_LIVE_DEV_STARTED=0
  LASTDB_DEV_HOME="$NS_LIVE_DEV_HOME" LASTDB_DEV_STATE="$NS_LIVE_DEV_STATE" \
    lastdb-dev stop >/dev/null 2>&1 || true
}
trap ns_live_dev_stop EXIT

ns_live_autoboot() {
  # Boot a private dev node. Prints its socket path on stdout; everything else
  # goes to stderr so the caller can capture the path cleanly.
  if ! ns_require_cmd lastdb-dev; then
    return 1
  fi
  NS_LIVE_DEV_HOME="${NORTH_STAR_PROOF_LASTDB_HOME:-$HOME/.lastdb-ns-delete-returns-bytes}"
  NS_LIVE_DEV_STATE="${NORTH_STAR_PROOF_LASTDB_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/lastdb-ns-delete-returns-bytes}"
  local -a sel
  if [ -n "${NORTH_STAR_PROOF_LASTDB_BIN:-}" ]; then
    sel=(--bin "$NORTH_STAR_PROOF_LASTDB_BIN")
  else
    # The claim under proof is about current main, so measure the staged build
    # of current main rather than whatever happens to be installed.
    sel=(--canary)
  fi
  if ! LASTDB_DEV_HOME="$NS_LIVE_DEV_HOME" LASTDB_DEV_STATE="$NS_LIVE_DEV_STATE" \
      lastdb-dev up "${sel[@]}" >&2; then
    return 1
  fi
  NS_LIVE_DEV_STARTED=1
  printf '%s\n' "$NS_LIVE_DEV_HOME/data/folddb.sock"
}

ns_live_home_for_socket() {
  # <home>/data/folddb.sock -> <home>
  printf '%s\n' "$(cd "$(dirname "$(dirname "$1")")" 2>/dev/null && pwd -P)"
}

ns_compact_json() {
  # ns_compact_json <home> <collection> <dry|execute> <out-file>
  local home="$1" coll="$2" phase="$3" out="$4"
  local -a args
  args=(--data-dir "$home" db compact --collection "$coll" --json)
  if [ "$phase" = execute ]; then
    args+=(--execute)
  fi
  # An owner compact rewrites a multi-GiB plane; the default admin deadline is
  # far shorter than that job, and a timeout here would read as a failed proof
  # rather than as an impatient client.
  LASTDB_UDS_ADMIN_TIMEOUT_SECS="${NORTH_STAR_PROOF_ADMIN_TIMEOUT_SECS:-3600}" \
    lastdb "${args[@]}" >"$out" 2>&1
}

ns_json_num() {
  # Prints the numeric field, or "null" when absent/non-numeric. Never fails,
  # so a missing field becomes a named gate failure instead of a set -e abort.
  jq -r --arg f "$2" '.[$f] // "null" | if type == "number" then tostring else "null" end' \
    "$1" 2>/dev/null || printf 'null\n'
}

measure_one_plane() {
  # Returns 0 only when this plane both shrank and left no unmeasured residue.
  local home="$1" coll="$2" work="$3"
  local dry="$work/$coll.dry.json" exec_out="$work/$coll.exec.json" post="$work/$coll.post.json"

  if ! ns_compact_json "$home" "$coll" dry "$dry"; then
    append "live/$coll: FAIL — dry-run compact failed: $(tr '\n' ' ' <"$dry" | cut -c1-200)"
    return 1
  fi
  local dead before_dry unknown_dry
  dead="$(ns_json_num "$dry" dead_bytes)"
  before_dry="$(ns_json_num "$dry" bytes_before)"
  unknown_dry="$(ns_json_num "$dry" residue_unknown_bytes)"
  append "live/$coll: dry-run bytes_before=$before_dry dead_bytes=$dead residue_unknown_bytes=$unknown_dry"

  if ! ns_compact_json "$home" "$coll" execute "$exec_out"; then
    append "live/$coll: FAIL — execute compact failed: $(tr '\n' ' ' <"$exec_out" | cut -c1-200)"
    return 1
  fi
  local skipped executed before after
  skipped="$(jq -r '.skipped_reason // ""' "$exec_out" 2>/dev/null || printf '')"
  executed="$(jq -r '.executed // false' "$exec_out" 2>/dev/null || printf 'false')"
  before="$(ns_json_num "$exec_out" bytes_before)"
  after="$(ns_json_num "$exec_out" bytes_after)"
  if [ -n "$skipped" ]; then
    append "live/$coll: FAIL — compact skipped: $skipped"
    return 1
  fi
  if [ "$executed" != true ]; then
    append "live/$coll: FAIL — compact reported executed=$executed; no rewrite happened"
    return 1
  fi
  if [ "$before" = null ] || [ "$after" = null ]; then
    append "live/$coll: FAIL — compact reported bytes_before=$before bytes_after=$after; the plane did not report a measured size"
    return 1
  fi
  if [ "$after" -ge "$before" ]; then
    append "live/$coll: FAIL — bytes_after=$after is not below bytes_before=$before; the delete did not return the bytes (dead_bytes was $dead)"
    return 1
  fi
  append "live/$coll: bytes_before=$before -> bytes_after=$after reclaimed=$((before - after))"

  # The reclaim number only means something if the store can account for the
  # whole plane. Unmeasured residue is space nobody can attribute, so a
  # shrink with unknown bytes left over is not a proof that delete returns them.
  if ! ns_compact_json "$home" "$coll" dry "$post"; then
    append "live/$coll: FAIL — follow-up dry-run compact failed: $(tr '\n' ' ' <"$post" | cut -c1-200)"
    return 1
  fi
  local unknown_post
  unknown_post="$(ns_json_num "$post" residue_unknown_bytes)"
  if [ "$unknown_post" != 0 ]; then
    append "live/$coll: FAIL — residue_unknown_bytes=$unknown_post after compact; some bytes are still unaccounted for"
    return 1
  fi
  append "live/$coll: residue_unknown_bytes=0 after compact — every byte in the plane is accounted for"
  return 0
}

run_live_measurement() {
  local sock="${NORTH_STAR_PROOF_SOCKET:-}"
  local booted=0
  if [ -z "$sock" ]; then
    if [ "${NORTH_STAR_PROOF_LIVE_AUTOBOOT:-1}" = 0 ]; then
      append "live: NORTH_STAR_PROOF_SOCKET unset and autoboot disabled — a CoW clone on an isolated socket is required"
      return 1
    fi
    if ! sock="$(ns_live_autoboot)"; then
      append "live: could not boot a private CoW dev node — see the lastdb-dev output above"
      return 1
    fi
    booted=1
  fi
  if ! ns_refuse_primary "$sock"; then
    append "live: refused — $sock is the primary brain"
    return 1
  fi
  if ! ns_require_cmd lastdb || ! ns_require_cmd jq; then
    append "live: lastdb and jq are both required for the byte measurement"
    return 1
  fi
  local home
  home="$(ns_live_home_for_socket "$sock")"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    append "live: FAIL — cannot resolve a node home from socket $sock"
    return 1
  fi
  if ! ns_refuse_primary "$home/data/folddb.sock"; then
    append "live: refused — $home resolves to the primary brain home"
    return 1
  fi
  if [ "$booted" -eq 1 ]; then
    append "live: measurement on a private CoW clone booted by this harness ($home)"
  else
    append "live: measurement against caller-supplied isolated socket $sock"
  fi

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/ns-delete-bytes-live.XXXXXX")"
  local rc=0 coll
  for coll in atoms tips; do
    measure_one_plane "$home" "$coll" "$work" || rc=1
  done
  rm -rf "$work"
  ns_live_dev_stop
  return "$rc"
}

ok=0
require_fold_tree || ok=1
if [ "$ok" -eq 0 ]; then
  check_delete_is_single_write   || ok=1
  check_purge_updates_search_index || ok=1
  check_embedding_ledger_is_honest || ok=1
  check_purge_tombstone_delivery_tested || ok=1
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
