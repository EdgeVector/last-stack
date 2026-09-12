#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-cloud-owned-gc
# Registration only: there is deliberately NO full-release success path.
# P9 must supply a reviewed release-evidence validator before that can change.
# A pinned verifier's exit zero, stdout, JSON, or Markdown is not release truth.
set -euo pipefail
umask 077

SLUG=north-star-lastdb-cloud-owned-gc
PROOF_DIR="${NORTH_STAR_PROOF_DIR:-$HOME/.last-stack/north-star-proofs}"
REPORT="$PROOF_DIR/$SLUG.md"
REASON=HARNESS_UNEXPECTED_EXIT
MODE=not_validated
TREE_OID=unverified
VERIFIER_BLOB=unverified
VERIFIER_RC=not_run

# Use only shell builtins on the existing-report path. A prior PASS must be
# invalidated BEFORE dirname, helper loading, source lookup, or child work.
# This intentionally does not use ns_write_report: that helper needs a loaded
# source tree and returns nonzero for FAIL under set -e.
write_failure_report() {
  {
    printf 'FAIL\n\n# North Star proof — %s\n\n' "$SLUG"
    printf 'Reason: %s\nMode: %s\n' "$REASON" "$MODE"
    printf 'Scope: registration-only; full release unproven\n'
    printf 'Source commit: %s\nVerifier blob: %s\nVerifier exit: %s\n' \
      "$TREE_OID" "$VERIFIER_BLOB" "$VERIFIER_RC"
    printf 'Required command: ./scripts/prove-cloud-owned-gc --require-full-release-proof\n'
    printf 'P9 release-evidence acceptance is not implemented. No payload or child output is included.\n'
  } >"$REPORT"
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap, including setup failures.
finish() {
  local rc="$1"
  trap - EXIT HUP INT TERM
  if ! write_failure_report; then
    printf 'PROOF_REASON=PROOF_REPORT_UNWRITABLE\n' >&2
  fi
  printf 'PROOF_VERDICT=FAIL\nPROOF_REASON=%s\n' "$REASON"
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}
fail() { REASON="$1"; exit "${2:-1}"; }

# Creating a missing report directory is the only prerequisite to the first
# invalidation. If it cannot be written, refuse all child execution.
if [ ! -d "$PROOF_DIR" ]; then
  mkdir -p "$PROOF_DIR" 2>/dev/null || {
    printf 'PROOF_VERDICT=FAIL\nPROOF_REASON=PROOF_REPORT_UNWRITABLE\n' >&2
    exit 1
  }
fi
trap 'finish "$?"' EXIT
trap 'REASON=HARNESS_INTERRUPTED; exit 129' HUP
trap 'REASON=HARNESS_INTERRUPTED; exit 130' INT
trap 'REASON=HARNESS_INTERRUPTED; exit 143' TERM
write_failure_report || fail PROOF_REPORT_UNWRITABLE

# An environment hint is not a safety fence. Reject before even resolving the
# source; offline/unknown must never reach a child or a mirror archive helper.
case "${NORTH_STAR_PROOF_MODE-offline}" in
  live) MODE=live ;;
  offline) MODE=offline; fail FULL_RELEASE_PROOF_REQUIRES_LIVE_MODE ;;
  *) MODE=invalid; fail UNSUPPORTED_PROOF_MODE ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

# ns_repo_path's implicit portal/main archive has no verified release identity.
# Only an explicit override is supported until an exact release-source resolver
# exists. Both existing override names still work, with the same strict pin.
SOURCE="${CLOUD_OWNED_GC_FOLD_SOURCE:-${FOLD_REPO:-}}"
[ -n "$SOURCE" ] || fail FOLD_SOURCE_REQUIRED
[ -d "$SOURCE" ] || fail FOLD_SOURCE_MISSING
FOLD="$(FOLD_REPO="$SOURCE" ns_repo_path fold)"
FOLD="$(cd "$FOLD" && pwd -P)" || fail FOLD_SOURCE_MISSING
[ ! -e "$FOLD/.portal" ] && [ ! -L "$FOLD/.portal" ] || fail FOLD_SOURCE_IS_PORTAL
[ -f "$FOLD/.git" ] || [ -d "$FOLD/.git" ] || fail FOLD_SOURCE_NOT_GIT_ROOT

PIN="${CLOUD_OWNED_GC_FOLD_SOURCE_OID:-}"
[ -n "$PIN" ] || fail FOLD_SOURCE_PIN_REQUIRED
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || fail FOLD_SOURCE_PIN_INVALID

source_git() (
  # A caller's repository environment must not redirect these identity checks.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 \
    git -c core.fsmonitor=false -c core.untrackedCache=false -C "$FOLD" "$@"
)
TOP="$(source_git rev-parse --show-toplevel 2>/dev/null)" || fail FOLD_SOURCE_NOT_GIT_ROOT
[ "$TOP" = "$FOLD" ] || fail FOLD_SOURCE_NOT_GIT_ROOT
HEAD_OID="$(source_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || fail FOLD_SOURCE_PIN_MISMATCH
[ "$HEAD_OID" = "$PIN" ] || fail FOLD_SOURCE_PIN_MISMATCH
TREE_OID="$HEAD_OID"

VERIFIER_REL=scripts/prove-cloud-owned-gc
VERIFIER="$FOLD/$VERIFIER_REL"
[ ! -L "$FOLD/scripts" ] && [ ! -L "$VERIFIER" ] || fail VERIFIER_SYMLINK_REFUSED
[ -f "$VERIFIER" ] || fail MISSING_FOLD_P9_VERIFIER
[ -x "$VERIFIER" ] || fail VERIFIER_NOT_EXECUTABLE
ENTRY="$(source_git ls-tree "$PIN" -- "$VERIFIER_REL" 2>/dev/null)" || fail VERIFIER_NOT_PINNED
read -r ENTRY_MODE ENTRY_TYPE ENTRY_BLOB ENTRY_PATH <<<"$ENTRY"
[ "$ENTRY_MODE" = 100755 ] && [ "$ENTRY_TYPE" = blob ] && [ "$ENTRY_PATH" = "$VERIFIER_REL" ] || fail VERIFIER_NOT_PINNED

# Status alone can miss assume-unchanged/skip-worktree verifier edits. Compare
# raw bytes to the pinned blob too; do not apply Git's clean/smudge filters.
ACTUAL_BLOB="$(source_git hash-object --no-filters "$VERIFIER" 2>/dev/null)" || fail VERIFIER_BYTES_MISMATCH
[ "$ACTUAL_BLOB" = "$ENTRY_BLOB" ] || fail VERIFIER_BYTES_MISMATCH
VERIFIER_BLOB="$ENTRY_BLOB"
INDEX_FLAGS="$(source_git ls-files -v 2>/dev/null)" || fail FOLD_SOURCE_INSPECTION_FAILED
# Dirty dependencies must not hide behind index trust flags either. Refuse an
# incomplete inspection (including sparse sources), not only a dirty verifier.
if grep -qE '^[a-zS] ' <<<"$INDEX_FLAGS"; then
  fail FOLD_SOURCE_INDEX_FLAGS_UNSAFE
fi
DIRTY="$(source_git status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || fail FOLD_SOURCE_INSPECTION_FAILED
[ -z "$DIRTY" ] || fail FOLD_SOURCE_DIRTY

# The source remains caller-owned and must stay immutable for the invocation.
# This is not a sandbox for untrusted code and grants no production authority.
# Keep the durable report failed during the child, including uncatchable death.
write_failure_report || fail PROOF_REPORT_UNWRITABLE
if (
  cd "$FOLD" || exit 125
  # Retire the old self-certifying Markdown handoff. No evidence input is read,
  # no nonce conveys authority, and no raw output is retained, even on failure.
  unset CLOUD_OWNED_GC_PROOF_NONCE BASH_ENV ENV
  export CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE=/dev/null NORTH_STAR_PROOF_MODE=live
  exec "./$VERIFIER_REL" --require-full-release-proof
) >/dev/null 2>&1; then
  VERIFIER_RC=0
else
  VERIFIER_RC=$?
fi
[ "$VERIFIER_RC" -eq 0 ] || fail VERIFIER_NONZERO_EXIT "$VERIFIER_RC"

# An explicit code change and reviewed P9 validator are required to remove this
# gate. No environment override, checklist, JSON value, or token can bypass it.
fail FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED
