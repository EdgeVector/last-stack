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
# Live runs that copy proof against a private CoW clone. The clone uses the
# same cp -cR method as lastdb-dev (bin/last-stack-lastdb-dev,
# clone_from_primary). The target is never ~/.lastdb, ~/.folddb, or the
# shared ~/.lastdb-dev home.
#
# LOGICAL_RESIDENT_SET_FOLD_MIRROR overrides the mirror for fixture tests.
# LOGICAL_RESIDENT_SET_FOLD_REF overrides the ref. An empty override keeps
# the origin/main lookup.
# LOGICAL_RESIDENT_SET_COPY_HOME supplies an existing copy in live mode.
# The harness still refuses a home under ~/.lastdb or ~/.folddb.
#
# Live mode extracts the WHOLE Fold tree at the resolved commit, not only
# the copy proof script: the script runs `cargo test -p fold_db` from its
# own repo root, so a lone script fails with "could not find Cargo.toml"
# and the proof can never pass. CARGO_TARGET_DIR defaults to a directory
# inside the scratch dir so the build is removed with it; set
# LOGICAL_RESIDENT_SET_CARGO_TARGET_DIR to reuse a build across runs.
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
PIECES=("$PIECE_SCRIPT" "$PIECE_RANGE" "$PIECE_SET")
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
    printf 'Copy proof: %s --home <copy-path>\n' "$PIECE_SCRIPT"
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

cow_clone() {
  local src dest src_id dest_id
  src="${LASTDB_DEV_PRIMARY_HOME:-$HOME/.lastdb}"
  [ -d "$src" ] || finish FAIL "The primary home is absent."
  dest="$TMP/cow-home"
  case "$dest" in
    "$TMP"/*) ;;
    *) finish FAIL "The CoW target is outside the scratch directory." ;;
  esac
  refuse_home "$dest"
  if [ "$(uname -s)" = Darwin ]; then
    cp -cR "$src" "$dest" 2>"$TMP/clone.err" || true
  else
    cp -a "$src" "$dest" 2>"$TMP/clone.err" || true
  fi
  [ -d "$dest/data" ] || finish FAIL "The CoW clone is incomplete."
  [ ! -L "$dest" ] || finish FAIL "The CoW clone is a symlink."
  refuse_home "$dest"
  src_id="$(python3 -c 'import os, sys; s=os.stat(sys.argv[1]); print("%s:%s" % (s.st_dev, s.st_ino))' "$src")"
  dest_id="$(python3 -c 'import os, sys; s=os.stat(sys.argv[1]); print("%s:%s" % (s.st_dev, s.st_ino))' "$dest")"
  [ "$src_id" != "$dest_id" ] || finish FAIL "The CoW clone aliases the primary home."
  rm -f "$dest/data/folddb.sock" "$dest/data/folddb-full.sock" "$dest/data.app-sock" \
    "$dest/cloud_sync.json" "$dest/current-session.json" 2>/dev/null || true
  rm -f "$dest"/cloud_sync.json* 2>/dev/null || true
  COPY_PATH="$dest"
}

run_copy_proof() {
  local copy="$1" script child_report child_rc child_line verdict note body
  refuse_home "$copy"
  [ -d "$copy" ] || finish FAIL "The copy home is absent."
  [ ! -L "$copy" ] || finish FAIL "The harness refuses a symlink home."
  script="$TMP/fold/$PIECE_SCRIPT"
  mkdir -p "$TMP/fold"
  if ! fold_git archive "$RESOLVED" | tar -x -C "$TMP/fold"; then
    finish FAIL "The harness could not extract the Fold tree."
  fi
  [ -f "$script" ] || finish FAIL "The copy proof script did not extract."
  [ -f "$TMP/fold/Cargo.toml" ] || finish FAIL "The extracted Fold tree has no Cargo.toml."
  child_report="$TMP/child-report.md"
  set +e
  CARGO_TARGET_DIR="${LOGICAL_RESIDENT_SET_CARGO_TARGET_DIR:-$TMP/target}" \
    bash "$script" --home "$copy" --report "$child_report" >"$TMP/child.out" 2>"$TMP/child.err"
  child_rc=$?
  set -e
  child_line=""
  if [ -f "$child_report" ]; then
    child_line="$(sed -n '1p' "$child_report" | tr -d '\r')"
  fi
  if [ -z "$child_line" ] && [ -s "$TMP/child.out" ]; then
    child_line="$(sed -n '1p' "$TMP/child.out" | tr -d '\r')"
  fi
  note=""
  case "$child_line" in
    PASS)
      if [ "$child_rc" -ne 0 ]; then
        verdict=FAIL
        note="The copy proof printed PASS and exited ${child_rc}."
      else
        verdict=PASS
      fi
      ;;
    FAIL)
      verdict=FAIL
      ;;
    *)
      verdict=FAIL
      note="The copy proof did not print PASS or FAIL."
      ;;
  esac
  body="$(
    {
      printf 'The copy proof returned %s.\n' "$verdict"
      printf 'Copy home: %s\n' "$copy"
      printf 'Child exit: %s\n' "$child_rc"
      printf 'Child first line: %s\n' "${child_line:-empty}"
      printf 'Mirror: %s\n' "$MIRROR"
      printf 'Ref: %s\n' "$REQUESTED_REF"
      printf 'Resolved: %s\n' "$RESOLVED"
      printf 'Oid: %s\n' "$OID"
      printf 'Mode: live\n'
      printf 'Copy proof: %s --home <copy-path>\n' "$PIECE_SCRIPT"
      if [ -n "$note" ]; then
        printf '%s\n' "$note"
      fi
      if [ -f "$child_report" ]; then
        printf '\nChild report:\n'
        sed -n '1,40p' "$child_report"
      fi
    }
  )"
  finish "$verdict" "$body"
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

if [ "$MODE" = offline ]; then
  finish PASS-OFFLINE "$(source_body "The bare mirror holds the three Fold pieces." "$OID" "" "$PRESENT_TEXT")"
fi

if [ -n "${LOGICAL_RESIDENT_SET_COPY_HOME:-}" ]; then
  refuse_home "$LOGICAL_RESIDENT_SET_COPY_HOME"
  run_copy_proof "$LOGICAL_RESIDENT_SET_COPY_HOME"
fi

cow_clone
run_copy_proof "$COPY_PATH"
