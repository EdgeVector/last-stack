# shellcheck shell=bash
# Shared helpers for North Star terminal proof harnesses.
# Never touch the primary brain socket.

ns_edgevector_workspace() {
  printf '%s\n' "${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}"
}

ns_repo_path() {
  # Resolve an EdgeVector repo slug for proof harnesses. Workspace entries may
  # be portals; proofs need a concrete source tree but must not edit the portal.
  local slug="$1"
  local env_name candidate cache tmp
  env_name="$(printf '%s_REPO' "$slug" | tr '[:lower:]-' '[:upper:]_')"
  candidate="${!env_name:-}"
  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(ns_edgevector_workspace)/$slug"
  if [ -f "$candidate/.portal/cache" ]; then
    cache="$(tr -d '[:space:]' <"$candidate/.portal/cache")"
    if [ -n "$cache" ] && git --git-dir="$cache" rev-parse --verify --quiet main^{commit} >/dev/null 2>&1; then
      tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-${slug}.XXXXXX")"
      git --git-dir="$cache" archive main | tar -x -C "$tmp"
      printf '%s\n' "$tmp"
      return 0
    fi
  fi

  printf '%s\n' "$candidate"
}

ns_proof_dir() {
  printf '%s\n' "${NORTH_STAR_PROOF_DIR:-$HOME/.last-stack/north-star-proofs}"
}

ns_now() {
  date -u +"%Y-%m-%dT%H:%MZ"
}

ns_refuse_primary() {
  # Call when about to use a LastDB socket path.
  local sock="${1:-}"
  case "$sock" in
    "$HOME/.lastdb/"*|"$HOME/.folddb/"*)
      echo "FAIL: refusing primary brain path: $sock" >&2
      return 1
      ;;
  esac
  return 0
}

ns_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL: missing command: $1" >&2
    return 1
  }
}

ns_write_report() {
  # ns_write_report <slug> <PASS|FAIL|PASS-OFFLINE> <body-markdown>
  local slug="$1" verdict="$2" body="$3"
  local dir report
  dir="$(ns_proof_dir)"
  mkdir -p "$dir"
  report="$dir/${slug}.md"
  {
    printf '%s\n' "$verdict"
    printf '\n# North Star proof — %s\n\n' "$slug"
    printf 'Generated: %s\n\n' "$(ns_now)"
    printf '%s\n' "$body"
  } >"$report"
  printf 'PROOF_REPORT=%s\n' "$report"
  printf 'PROOF_VERDICT=%s\n' "$verdict"
  case "$verdict" in
    PASS|PASS-OFFLINE) return 0 ;;
    *) return 1 ;;
  esac
}

ns_mode() {
  # live | offline  (default offline for CI safety)
  printf '%s\n' "${NORTH_STAR_PROOF_MODE:-offline}"
}

# --- Fold source lanes -------------------------------------------------------
#
# A proof harness may grade Fold's source. The two proof TESTS used to assert
# that verdict over the Fold portal's CURRENT HEAD from inside ci-required, and
# both halves of that were wrong (measured 2026-09-26):
#
#   * fold merged a correct refactor (fold 2205, 74d7bb489) at 11:24Z and every
#     last-stack PR went red on it. The same last-stack tree ran the gate rc=0
#     at 11:22Z and rc=1 at 11:40Z with no last-stack change, and rc=1 on a
#     pristine `git archive origin/main` tree.
#     papercut-last-stack-ci-shard-grades-the-live-fold-portal-head-20260926
#   * the bare mirror's HEAD is refs/heads/main, which a registered worktree
#     freezes. It read 26f0f601f while fold's real main was 590ac314e, so the
#     gate did not even grade the tip it named.
#
# So the source verdict runs in two lanes:
#
#   blocking    the PINNED oid in harness/north-star/fold-source.pin. The gate's
#               answer is a function of this repo's commit alone, and moving the
#               pin is a deliberate reviewed change whose failure names the fold
#               commit.
#   reporting   the LIVE mirror head. A DRIFT notice on stdout, never an exit
#               code, carrying the graded oid and the rules that failed.
#
# The reporting lane caught a real drift question, so it stays. The blocking
# lane is what makes the gate reproducible.

ns_fold_source_pin_file() {
  # The pin lives next to this file so a test and a harness resolve it the same
  # way, with no $ROOT to get wrong.
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s\n' "${NORTH_STAR_FOLD_SOURCE_PIN_FILE:-$here/fold-source.pin}"
}

ns_fold_source_pin() {
  # Echo the pinned Fold oid. Return 1 when no pin is checked in, so a caller
  # can say so rather than grading an empty string.
  local file oid
  file="$(ns_fold_source_pin_file)"
  [ -f "$file" ] || return 1
  oid="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$file" | sed -n '1p' | tr -d '[:space:]')"
  [ -n "$oid" ] || return 1
  printf '%s\n' "$oid"
}

ns_fold_rev_present() {
  # ns_fold_rev_present <git-dir> <rev>: does this mirror hold that commit?
  local git_dir="$1" rev="$2"
  [ -d "$git_dir" ] || return 1
  git --git-dir="$git_dir" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null 2>&1
}

ns_fold_rev_label() {
  # ns_fold_rev_label <git-dir> <rev>: the resolved oid, or the rev itself when
  # this mirror cannot resolve it. Never fails: it is a label, not a lookup.
  local git_dir="$1" rev="$2" oid
  oid="$(git --git-dir="$git_dir" rev-parse "$rev" 2>/dev/null || true)"
  printf '%s\n' "${oid:-$rev}"
}

ns_fold_report_failures() {
  # Echo the report's own "Source failures:" block on one line. A report names
  # the exact rule that failed; a caller that omits it makes the reader re-run
  # the harness by hand to learn what this run already knew.
  # papercut-north-star-proof-test-fail-message-drops-the-report-reason-20260926
  local report="${1:-}"
  [ -f "$report" ] || { printf '%s\n' "(no report at $report)"; return 0; }
  sed -n '/^Source failures:/,/^$/p' "$report" | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/ $//'
}

ns_fold_source_absent() {
  # A report whose body says the source could not be loaded is an ENVIRONMENT
  # fact about this host's Fold mirror, not a verdict about anything. A gate
  # must not assert over it: an empty or unfetched mirror would then red every
  # PR, which is the defect the lanes exist to remove.
  local report="${1:-}"
  [ -f "$report" ] || return 0
  grep -q '^The Fold source is absent' "$report"
}

ns_fold_drift_report() {
  # ns_fold_drift_report <what> <oid> <report>: the REPORTING lane. Print what
  # the live Fold source says and ALWAYS return 0 — this lane must never set a
  # gate's exit code, because the commit it grades is in another repository.
  local what="$1" oid="$2" report="$3"
  if [ ! -f "$report" ]; then
    printf 'fold-source-drift: %s oid=%s report=absent\n' "$what" "$oid"
    return 0
  fi
  if grep -q '^Source contract: PASS' "$report"; then
    printf 'fold-source-drift: %s oid=%s source=PASS\n' "$what" "$oid"
    return 0
  fi
  printf 'fold-source-drift: %s oid=%s source=FAIL rules=%s\n' \
    "$what" "$oid" "$(ns_fold_report_failures "$report")"
  printf 'fold-source-drift: this is a REPORT about EdgeVector/fold, not a last-stack failure. Fix fold or move harness/north-star/fold-source.pin deliberately.\n'
  return 0
}
