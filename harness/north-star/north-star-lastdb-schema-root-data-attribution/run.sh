#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-schema-root-data-attribution
# Offline terminal proof for schema-root data attribution.
# Reads the Fold attribution contract and one throwaway object graph.
# Does not open a LastDB home. Does not reclaim residue on a shared node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-schema-root-data-attribution
MODE="$(ns_mode)"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHECK="$HERE/check_contract.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/schema-root-attribution-proof.XXXXXX")"

SOURCE_FILES=(
  fold_db/crates/core/src/db_operations/attribution_ledger.rs
  lastdb_node/src/attribution_epoch.rs
  fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs
  fold_db/crates/core/src/schema/core/tests.rs
)

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
  local path="$1" canon
  canon="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path")" || return 1
  printf '%s\n' "$canon"
}

refuse_primary() {
  local candidate="$1" canon root
  [ -n "$candidate" ] || return 0
  canon="$(canonical_path "$candidate")" || finish FAIL "The harness could not resolve the path."
  for root in "$HOME/.lastdb" "$HOME/.folddb"; do
    if [ -e "$root" ] || [ -L "$root" ]; then
      root="$(canonical_path "$root")" || finish FAIL "The harness could not resolve the primary home."
    fi
    case "$canon" in
      "$root"|"$root"/*)
        finish FAIL "The harness refuses a LastDB home path."
        ;;
    esac
  done
}

copy_from_tree() {
  local repo="$1" rel dest
  refuse_primary "$repo"
  for rel in "${SOURCE_FILES[@]}"; do
    dest="$TMP/src/$rel"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$repo/$rel" ]; then
      refuse_primary "$repo/$rel"
      cp "$repo/$rel" "$dest"
    else
      return 1
    fi
  done
}

copy_from_git() {
  local git_dir="$1" rel dest
  refuse_primary "$git_dir"
  [ -d "$git_dir" ] || return 1
  for rel in "${SOURCE_FILES[@]}"; do
    dest="$TMP/src/$rel"
    mkdir -p "$(dirname "$dest")"
    if ! git --git-dir="$git_dir" show "HEAD:$rel" >"$dest"; then
      return 1
    fi
    [ -s "$dest" ] || return 1
  done
}

# A linked worktree stores "gitdir: <path>" in a .git file. Git resolves
# that file. Do not parse it: a space-stripping parser never sees "gitdir: ".
copy_from_checkout() {
  local repo="$1" rel dest
  refuse_primary "$repo"
  refuse_primary "$repo/.git"
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
    return 1
  fi
  for rel in "${SOURCE_FILES[@]}"; do
    dest="$TMP/src/$rel"
    mkdir -p "$(dirname "$dest")"
    if ! git -C "$repo" show "HEAD:$rel" >"$dest"; then
      return 1
    fi
    [ -s "$dest" ] || return 1
  done
}

load_source() {
  local explicit repo portal cache ws
  explicit="${SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR:-}"
  if [ -n "$explicit" ]; then
    refuse_primary "$explicit"
    copy_from_tree "$explicit" || finish FAIL "The Fold source is absent."
    printf '%s\n' "$explicit"
    return 0
  fi

  repo="${FOLD_REPO:-}"
  if [ -n "$repo" ]; then
    if copy_from_tree "$repo"; then
      printf '%s\n' "$repo"
      return 0
    fi
    if copy_from_checkout "$repo"; then
      printf '%s\n' "git:$repo:HEAD"
      return 0
    fi
    finish FAIL "The Fold source is absent."
  fi

  portal="$(ns_edgevector_workspace)/fold/.portal/cache"
  if [ -f "$portal" ]; then
    cache="$(tr -d '[:space:]' <"$portal")"
    copy_from_git "$cache" || finish FAIL "The Fold source is absent."
    printf '%s\n' "fold-portal:HEAD"
    return 0
  fi

  ws="$(ns_edgevector_workspace)/fold"
  if copy_from_tree "$ws"; then
    printf '%s\n' "fold-worktree"
    return 0
  fi
  if copy_from_checkout "$ws"; then
    printf '%s\n' "git:$ws:HEAD"
    return 0
  fi
  finish FAIL "The Fold source is absent."
}

refuse_primary "$(ns_proof_dir)"

if [ "$MODE" != offline ]; then
  finish FAIL "This harness runs in offline mode only. It does not reclaim residue and it does not open a LastDB home."
fi

if [ -n "${SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE:-}" ]; then
  finish FAIL "This harness does not delete from a source home. Remove SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE."
fi

if [ -n "${SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER:-}" ]; then
  finish FAIL "This harness does not run a production cutover. Remove SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER."
fi

load_source >"$TMP/source-label"
SOURCE_LABEL="$(sed -n '1p' "$TMP/source-label")"

EVIDENCE="${SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE:-}"
if [ -n "$EVIDENCE" ]; then
  refuse_primary "$EVIDENCE"
  [ -f "$EVIDENCE" ] || finish FAIL "The evidence file is absent."
fi

set +e
BODY="$(python3 "$CHECK" "$TMP/src" "$EVIDENCE" 2>"$TMP/check.err")"
RC=$?
set -e
if [ -s "$TMP/check.err" ]; then
  BODY="${BODY}

Checker error:
$(cat "$TMP/check.err")"
fi
BODY="${BODY}

Source label: ${SOURCE_LABEL}"

if [ "$RC" -ne 0 ]; then
  finish FAIL "$BODY"
fi
finish PASS-OFFLINE "$BODY"
