#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-logical-resident-set
# Terminal proof for North Star "LastDB Memory Keeps Keys".
#
# Offline reads EdgeVector/lastdb origin/main from the bare mirror
# ~/.cache/edgevector-git/lastdb.git. It does not fetch. It does not open a
# LastDB home. It names each absent piece:
#   fold_db/scripts/logical-resident-set-copy-proof.sh
#   fold_db/crates/core/src/resident/range.rs
#   fold_db/crates/core/src/resident/logical_set.rs
#
# The old delegated test suite is retired by no-tests-all-repos-20261009.
# This harness checks source only and cannot produce a live PASS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-logical-resident-set
MODE="$(ns_mode)"
MIRROR="${LOGICAL_RESIDENT_SET_FOLD_MIRROR:-$HOME/.cache/edgevector-git/lastdb.git}"
PIECE_SCRIPT="fold_db/scripts/logical-resident-set-copy-proof.sh"
PIECE_RANGE="fold_db/crates/core/src/resident/range.rs"
PIECE_SET="fold_db/crates/core/src/resident/logical_set.rs"
PIECES=("$PIECE_RANGE" "$PIECE_SET")
REQUESTED_REF="${LOGICAL_RESIDENT_SET_FOLD_REF:-origin/main}"
RESOLVED=""
TMP=""

cleanup() {
  case "${TMP:-}" in
    ""|/|"$HOME"|/tmp|/private/tmp) return 0 ;;
  esac
  case "$TMP" in
    /tmp/*|/private/tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$TMP" ;;
  esac
}
trap cleanup EXIT

finish() {
  local verdict="$1" body="$2" rc=0
  set +e
  ns_write_report "$SLUG" "$verdict" "$body"
  rc=$?
  set -e
  if [ "$verdict" = PASS ] || [ "$verdict" = PASS-OFFLINE ]; then
    if [ "$rc" -ne 0 ]; then
      exit 1
    fi
    exit 0
  fi
  exit 1
}

fold_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    git --git-dir="$MIRROR" "$@"
}

# Exit 0 when the path is the primary home or sits under it.
# Exit 1 when the path is safe. Exit 2 when the path cannot be resolved.
home_is_forbidden() {
  python3 -c '
import os, sys
candidate = sys.argv[1]
roots = sys.argv[2:]
if not candidate:
    raise SystemExit(2)
try:
    canon = os.path.realpath(candidate)
except OSError:
    raise SystemExit(2)
def norm(path):
    if os.path.lexists(path):
        return os.path.realpath(path)
    return os.path.abspath(path)
for root in roots:
    base = norm(root)
    if canon == base or canon.startswith(base + os.sep):
        raise SystemExit(0)
raise SystemExit(1)
' "$1" "$HOME/.lastdb" "$HOME/.folddb"
}

refuse_home() {
  local rc=0
  set +e
  home_is_forbidden "$1"
  rc=$?
  set -e
  case "$rc" in
    0) finish FAIL "The harness refuses a home under the primary LastDB path." ;;
    1) ;;
    *) finish FAIL "The harness could not resolve the home path." ;;
  esac
  if [ -L "$1" ]; then
    finish FAIL "The harness refuses a symlink home."
  fi
}

piece_lines() {
  local rel
  for rel in "${PIECES[@]}"; do
    printf -- '- %s\n' "$rel"
  done
}

print_block() {
  local text="$1"
  if [ -z "$text" ]; then
    printf '%s\n' "- none"
    return 0
  fi
  printf '%s' "$text"
  case "$text" in
    *$'\n') ;;
    *) printf '\n' ;;
  esac
}

source_body() {
  local headline="$1" oid="$2" absent_text="$3" present_text="$4"
  {
    printf '%s\n' "$headline"
    printf 'Mirror: %s\n' "$MIRROR"
    printf 'Ref: %s\n' "$REQUESTED_REF"
    printf 'Resolved: %s\n' "${RESOLVED:-absent}"
    printf 'Oid: %s\n' "$oid"
    printf 'Mode: %s\n' "$MODE"
    printf '\nAbsent pieces:\n'
    print_block "$absent_text"
    printf '\nPresent pieces:\n'
    print_block "$present_text"
    printf '\n%s\n' "This run does not open a LastDB home."
    printf '%s\n' "This run does not run the copy proof."
  }
}

classify_pieces() {
  local rel kind
  ABSENT_TEXT=""
  PRESENT_TEXT=""
  for rel in "${PIECES[@]}"; do
    kind="$(fold_git cat-file -t "${RESOLVED}:${rel}" 2>/dev/null || true)"
    if [ "$kind" = blob ]; then
      PRESENT_TEXT="${PRESENT_TEXT}- ${rel}"$'\n'
    else
      ABSENT_TEXT="${ABSENT_TEXT}- ${rel}"$'\n'
    fi
  done
}

resolve_ref() {
  local candidate
  RESOLVED=""
  if [ -n "${LOGICAL_RESIDENT_SET_FOLD_REF:-}" ]; then
    if fold_git rev-parse --verify --quiet "${LOGICAL_RESIDENT_SET_FOLD_REF}^{commit}" >/dev/null; then
      RESOLVED="$LOGICAL_RESIDENT_SET_FOLD_REF"
      return 0
    fi
    return 1
  fi
  for candidate in origin/main refs/remotes/origin/main; do
    if fold_git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
      RESOLVED="$candidate"
      return 0
    fi
  done
  # A mirror clone stores the remote main branch at refs/heads/main.
  # Use it only when origin/main is not present.
  if fold_git rev-parse --verify --quiet 'refs/heads/main^{commit}' >/dev/null; then
    RESOLVED="refs/heads/main"
    return 0
  fi
  return 1
}

mirror_readable() {
  [ -d "$MIRROR" ] || return 1
  fold_git rev-parse --git-dir >/dev/null 2>&1
}

ns_require_cmd git || finish FAIL "The harness needs git."
ns_require_cmd python3 || finish FAIL "The harness needs python3."

case "$MODE" in
  live|offline) ;;
  *) finish FAIL "The proof mode is invalid: ${MODE}." ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lrs-proof.XXXXXX")"

if ! mirror_readable; then
  finish FAIL "$(source_body "The Fold bare mirror is absent." "absent" "$(piece_lines)" "")"
fi

if ! resolve_ref; then
  finish FAIL "$(source_body "The Fold ref ${REQUESTED_REF} is absent from the bare mirror." "absent" "$(piece_lines)" "")"
fi

OID="$(fold_git rev-parse "${RESOLVED}^{commit}")" || finish FAIL "The harness could not resolve the Fold commit."
classify_pieces

if [ -n "$ABSENT_TEXT" ]; then
  finish FAIL "$(source_body "The bare mirror does not hold every Fold piece." "$OID" "$ABSENT_TEXT" "$PRESENT_TEXT")"
fi

finish PASS-OFFLINE "$(source_body "The bare mirror holds the LastDB source pieces. The old test suite is retired; no live result is claimed." "$OID" "" "$PRESENT_TEXT")"
