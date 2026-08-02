#!/usr/bin/env bash
# Pure candidate-class gates for lastdb-safe-upgrade (incident 2026-08-01).
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# Rejects (unless env overrides):
#   - path under target/debug (Cargo debug profile)
#   - version stamp ending in -dirty (uncommitted tree at build)
#   - file size ≫ incumbent (default >1.5× baseline binary bytes)
#
# Overrides (Tom clearance only):
#   LASTDB_ALLOW_DEBUG_CANDIDATE=1
#   LASTDB_ALLOW_DIRTY_CANDIDATE=1
#   LASTDB_ALLOW_LARGE_CANDIDATE=1
#   LASTDB_CANDIDATE_SIZE_RATIO (default 1.5)

# rc 0 = Cargo target/debug path; rc 1 = not
candidate_path_is_debug() {
  local path="$1"
  case "$path" in
    */target/debug/*|*/target/debug) return 0 ;;
  esac
  return 1
}

# rc 0 = dirty version stamp; rc 1 = clean
candidate_version_is_dirty() {
  local ver="$1"
  case "$ver" in
    *-dirty|*-dirty.*|*+dirty*) return 0 ;;
  esac
  return 1
}

# Print integer file size in bytes, or 0 if unreadable.
candidate_file_bytes() {
  local path="$1" sz
  if [ ! -f "$path" ] && [ ! -x "$path" ]; then
    echo 0
    return
  fi
  sz="$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)"
  echo "${sz:-0}"
}

# rc 0 = candidate too large vs baseline; rc 1 = ok or no baseline
# $1 = candidate path, $2 = baseline path (optional empty), $3 = ratio (default 1.5)
candidate_size_ratio_over() {
  local cand="$1" base="${2:-}" ratio="${3:-1.5}"
  local cb bb
  cb="$(candidate_file_bytes "$cand")"
  [ "$cb" -gt 0 ] 2>/dev/null || return 1
  if [ -z "$base" ] || [ ! -e "$base" ]; then
    return 1
  fi
  bb="$(candidate_file_bytes "$base")"
  [ "$bb" -gt 0 ] 2>/dev/null || return 1
  # awk: cand > base * ratio
  awk -v c="$cb" -v b="$bb" -v r="$ratio" 'BEGIN{exit !(c > b*r)}'
}

# Validate candidate class. Prints human reasons to stdout (one per line).
# rc 0 = OK; rc 1 = RED (blocked)
# Args: candidate_path, version_string, optional_baseline_path
assert_candidate_class_ok() {
  local cand="$1" ver="$2" base="${3:-}"
  local reasons=() ratio
  ratio="${LASTDB_CANDIDATE_SIZE_RATIO:-1.5}"

  if candidate_path_is_debug "$cand"; then
    if [ "${LASTDB_ALLOW_DEBUG_CANDIDATE:-0}" = "1" ]; then
      printf 'WARN: candidate path looks like Cargo debug (%s) but LASTDB_ALLOW_DEBUG_CANDIDATE=1\n' "$cand"
    else
      reasons+=("path is Cargo debug profile (…/target/debug/…): $cand — build --release or use a release artifact (incident 2026-08-01)")
    fi
  fi

  if candidate_version_is_dirty "$ver"; then
    if [ "${LASTDB_ALLOW_DIRTY_CANDIDATE:-0}" = "1" ]; then
      printf 'WARN: candidate version is dirty (%s) but LASTDB_ALLOW_DIRTY_CANDIDATE=1\n' "$ver"
    else
      reasons+=("version stamp is dirty ($ver) — uncommitted tree at build; clean commit + release build only (incident 2026-08-01)")
    fi
  fi

  if [ -n "$base" ] && candidate_size_ratio_over "$cand" "$base" "$ratio"; then
    local cb bb
    cb="$(candidate_file_bytes "$cand")"
    bb="$(candidate_file_bytes "$base")"
    if [ "${LASTDB_ALLOW_LARGE_CANDIDATE:-0}" = "1" ]; then
      printf 'WARN: candidate size %s bytes > %sx baseline %s but LASTDB_ALLOW_LARGE_CANDIDATE=1\n' "$cb" "$ratio" "$bb"
    else
      reasons+=("candidate size ${cb} bytes is >${ratio}x baseline ${bb} bytes ($base) — usually a debug/unstripped build (incident 2026-08-01)")
    fi
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    local r
    for r in "${reasons[@]}"; do
      printf 'RED: %s\n' "$r"
    done
    return 1
  fi
  return 0
}
