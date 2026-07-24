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
