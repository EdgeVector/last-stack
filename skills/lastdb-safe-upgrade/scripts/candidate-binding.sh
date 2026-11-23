#!/usr/bin/env bash
# Exact-candidate binding for lastdb-safe-upgrade. Source this file.
# The immutable Loom tuple (source commit, paths, hashes, versions) names the
# candidate pair. These functions prove the pair on disk still matches it.

binding_sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    return 1
  fi
}

binding_binary_version() {
  local path="$1" out
  out="$("$path" --version 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '{print $NF}'
}

_binding_real_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_binding_real_file() {
  local path="$1" dir base
  [ -e "$path" ] || return 1
  dir="$(_binding_real_dir "$(dirname -- "$path")")" || return 1
  base="$(basename -- "$path")"
  if [ -L "$dir/$base" ]; then
    python3 - "$dir/$base" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  else
    printf '%s/%s\n' "$dir" "$base"
  fi
}

# Resolve a path that can no longer exist after the proof helper removes its

_binding_expected_value() {
  case "$1" in
    source_git_oid) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" ;;
    lastdbd_path) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH:-}" ;;
    lastdb_path) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH:-}" ;;
    lastdbd_sha256) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}" ;;
    lastdb_sha256) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}" ;;
    lastdbd_version) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION:-}" ;;
    lastdb_version) printf '%s\n' "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION:-}" ;;
    *) return 1 ;;
  esac
}

binding_expected_binding_is_complete() {
  local name value missing=0
  for name in source_git_oid lastdbd_path lastdb_path lastdbd_sha256 lastdb_sha256 lastdbd_version lastdb_version; do
    value="$(_binding_expected_value "$name" || true)"
    if [ -z "$value" ]; then
      printf 'RED: expected candidate binding has no %s\n' "$name"
      missing=1
    fi
  done
  if [ -z "${LOOM_EXEC_ID:-}" ]; then
    printf 'RED: expected candidate binding has no Loom execution id\n'
    missing=1
  fi
  [ "$missing" -eq 0 ]
}

# Verify that the exact on-disk pair still matches the immutable Loom tuple.
assert_candidate_binding_matches_expected() {
  local daemon="${1:-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH:-}}"
  local cli="${2:-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH:-}}"
  local source_oid="${3:-${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}}"
  local daemon_real cli_real daemon_sha cli_sha daemon_ver cli_ver failed=0

  binding_expected_binding_is_complete || return 1
  case "$source_oid" in
    *[!0-9a-f]*|'') printf 'RED: source Git OID is not lowercase hexadecimal\n'; failed=1 ;;
  esac
  [ "${#source_oid}" -eq 40 ] || { printf 'RED: source Git OID is not 40 characters\n'; failed=1; }
  [ -x "$daemon" ] || { printf 'RED: exact candidate lastdbd is not executable\n'; failed=1; }
  [ -x "$cli" ] || { printf 'RED: exact candidate lastdb is not executable\n'; failed=1; }
  [ "$failed" -eq 0 ] || return 1

  daemon_real="$(_binding_real_file "$daemon" || true)"
  cli_real="$(_binding_real_file "$cli" || true)"
  if [ "$daemon_real" != "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH}" ]; then
    printf 'RED: exact candidate lastdbd path changed after Loom kickoff\n'
    failed=1
  fi
  if [ "$cli_real" != "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH}" ]; then
    printf 'RED: exact candidate lastdb path changed after Loom kickoff\n'
    failed=1
  fi
  if [ "$(dirname -- "$daemon_real")" != "$(dirname -- "$cli_real")" ] \
      || [ "$(basename -- "$cli_real")" != "lastdb" ]; then
    printf 'RED: exact candidate lastdb is not the daemon sibling\n'
    failed=1
  fi

  daemon_sha="$(binding_sha256_file "$daemon_real" || true)"
  cli_sha="$(binding_sha256_file "$cli_real" || true)"
  daemon_ver="$(binding_binary_version "$daemon_real" || true)"
  cli_ver="$(binding_binary_version "$cli_real" || true)"
  [ "$daemon_sha" = "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256}" ] \
    || { printf 'RED: exact candidate lastdbd bytes changed after Loom kickoff\n'; failed=1; }
  [ "$cli_sha" = "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256}" ] \
    || { printf 'RED: exact candidate lastdb bytes changed after Loom kickoff\n'; failed=1; }
  [ "$daemon_ver" = "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION}" ] \
    || { printf 'RED: exact candidate lastdbd version changed after Loom kickoff\n'; failed=1; }
  [ "$cli_ver" = "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION}" ] \
    || { printf 'RED: exact candidate lastdb version changed after Loom kickoff\n'; failed=1; }
  [ "$daemon_ver" = "$cli_ver" ] \
    || { printf 'RED: exact candidate pair versions differ\n'; failed=1; }
  [ "$source_oid" = "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID}" ] \
    || { printf 'RED: exact candidate source Git OID changed after Loom kickoff\n'; failed=1; }
  [ "$failed" -eq 0 ]
}
