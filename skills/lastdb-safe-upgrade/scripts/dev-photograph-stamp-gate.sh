#!/usr/bin/env bash
# Exact-candidate DEV photograph receipt gate for lastdb-safe-upgrade.
# Source this file for its functions. Direct execution validates one receipt.

# A receipt can authorize a live cutover only when it names the exact Loom
# execution, source commit, daemon bytes, CLI bytes, and isolated DEV result.

LASTDB_DEV_BACKUP_API_URL_DEFAULT="https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com"
LASTDB_PROD_BACKUP_API_HOST="jdsx4ixk2i.execute-api.us-east-1.amazonaws.com"
LASTDB_DEV_STAMP_RECEIPT_VERSION="2"
LASTDB_DEV_STAMP_MAX_AGE_SECS_DEFAULT="3600"
LASTDB_DEV_STAMP_FUTURE_SKEW_SECS_DEFAULT="60"

dev_stamp_receipt_root() {
  printf '%s\n' "${LASTDB_DEV_STAMP_ROOT:-$HOME/.local/state/last-stack/lastdb-safe-upgrade/dev-photograph-receipts}"
}

dev_stamp_receipt_path() {
  printf '%s\n' "${LASTDB_DEV_STAMP_RECEIPT:-$(dev_stamp_receipt_root)/unbound.receipt}"
}

dev_stamp_api_is_prod() {
  case "$1" in
    *"${LASTDB_PROD_BACKUP_API_HOST}"*) return 0 ;;
  esac
  return 1
}

dev_stamp_api_is_dev() {
  [ "$1" = "$LASTDB_DEV_BACKUP_API_URL_DEFAULT" ]
}

dev_stamp_sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    return 1
  fi
}

dev_stamp_binary_version() {
  local path="$1" out
  out="$("$path" --version 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '{print $NF}'
}

_dev_stamp_real_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_dev_stamp_real_file() {
  local path="$1" dir base
  [ -e "$path" ] || return 1
  dir="$(_dev_stamp_real_dir "$(dirname -- "$path")")" || return 1
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
# temporary CoW. The result is lexical when no existing parent remains.
_dev_stamp_real_maybe_absent() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

_dev_stamp_file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

_dev_stamp_file_owner() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

_dev_stamp_required_keys() {
  cat <<'EOF'
receipt_version
verdict
loom_execution_id
source_git_oid
lastdbd_path
lastdb_path
lastdbd_sha256
lastdb_sha256
lastdbd_version
lastdb_version
api_url
home
primary_home
counter
cas_counter
manifest_sha256
latest_key
committed_at
committed_epoch
fresh_device_id
production_cloud_config_absent
production_cloud_residue_absent
production_presence_cache_absent
production_manifest_cache_absent
copied_session_absent
identity_preserved
bootstrap_preserved
EOF
}

_dev_stamp_key_is_known() {
  case "$1" in
    receipt_version|verdict|loom_execution_id|source_git_oid|lastdbd_path|lastdb_path|\
    lastdbd_sha256|lastdb_sha256|lastdbd_version|lastdb_version|api_url|home|\
    primary_home|counter|cas_counter|manifest_sha256|latest_key|committed_at|\
    committed_epoch|fresh_device_id|production_cloud_config_absent|\
    production_cloud_residue_absent|production_presence_cache_absent|\
    production_manifest_cache_absent|copied_session_absent|identity_preserved|\
    bootstrap_preserved) return 0 ;;
  esac
  return 1
}

dev_stamp_receipt_get() {
  local file="$1" key="$2" count
  [ -f "$file" ] || return 1
  count="$(awk -F= -v k="$key" '$1 == k {n++} END {print n+0}' "$file")"
  [ "$count" = "1" ] || return 1
  awk -v k="$key" 'index($0, k "=") == 1 {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

_dev_stamp_expected_value() {
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

dev_stamp_expected_binding_is_complete() {
  local name value missing=0
  for name in source_git_oid lastdbd_path lastdb_path lastdbd_sha256 lastdb_sha256 lastdbd_version lastdb_version; do
    value="$(_dev_stamp_expected_value "$name" || true)"
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

  dev_stamp_expected_binding_is_complete || return 1
  case "$source_oid" in
    *[!0-9a-f]*|'') printf 'RED: source Git OID is not lowercase hexadecimal\n'; failed=1 ;;
  esac
  [ "${#source_oid}" -eq 40 ] || { printf 'RED: source Git OID is not 40 characters\n'; failed=1; }
  [ -x "$daemon" ] || { printf 'RED: exact candidate lastdbd is not executable\n'; failed=1; }
  [ -x "$cli" ] || { printf 'RED: exact candidate lastdb is not executable\n'; failed=1; }
  [ "$failed" -eq 0 ] || return 1

  daemon_real="$(_dev_stamp_real_file "$daemon" || true)"
  cli_real="$(_dev_stamp_real_file "$cli" || true)"
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

  daemon_sha="$(dev_stamp_sha256_file "$daemon_real" || true)"
  cli_sha="$(dev_stamp_sha256_file "$cli_real" || true)"
  daemon_ver="$(dev_stamp_binary_version "$daemon_real" || true)"
  cli_ver="$(dev_stamp_binary_version "$cli_real" || true)"
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

_dev_stamp_time_is_valid() {
  local committed_at="$1" committed_epoch="$2"
  python3 - "$committed_at" "$committed_epoch" \
    "${LASTDB_DEV_STAMP_MAX_AGE_SECS:-$LASTDB_DEV_STAMP_MAX_AGE_SECS_DEFAULT}" \
    "${LASTDB_DEV_STAMP_FUTURE_SKEW_SECS:-$LASTDB_DEV_STAMP_FUTURE_SKEW_SECS_DEFAULT}" <<'PY'
import datetime
import re
import sys
import time

stamp, epoch_text, max_age_text, future_text = sys.argv[1:]
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", stamp):
    raise SystemExit(1)
try:
    parsed = int(datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc
    ).timestamp())
    epoch = int(epoch_text)
    max_age = int(max_age_text)
    future = int(future_text)
except (TypeError, ValueError, OverflowError):
    raise SystemExit(1)
if epoch <= 0 or parsed != epoch or max_age < 0 or future < 0:
    raise SystemExit(1)
now = int(time.time())
if epoch < now - max_age or epoch > now + future:
    raise SystemExit(1)
PY
}

_dev_stamp_paths_do_not_overlap() {
  local home="$1" primary="$2" home_r primary_r
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$primary" in /*) ;; *) return 1 ;; esac
  home_r="$(_dev_stamp_real_maybe_absent "$home")" || return 1
  primary_r="$(_dev_stamp_real_maybe_absent "$primary")" || return 1
  [ "$home_r" != "$primary_r" ] || return 1
  case "$home_r/" in "$primary_r/"*) return 1 ;; esac
  case "$primary_r/" in "$home_r/"*) return 1 ;; esac
  return 0
}

# Validate one v2 receipt. Every failure prints a fixed RED reason. Receipt
# values do not reach output because a path or cloud key can contain secrets.
assert_dev_photograph_stamp_ok() {
  local receipt="${1:-$(dev_stamp_receipt_path)}"
  local primary="${2:-${LASTDB_HOME:-$HOME/.lastdb}}"
  local failed=0 line key required value expected
  local mode home phome counter cas_counter committed_at committed_epoch

  if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
    printf 'RED: exact-candidate DEV photograph receipt is absent or unsafe\n'
    return 1
  fi
  mode="$(_dev_stamp_file_mode "$receipt" || true)"
  if [ "$mode" != "600" ]; then
    printf 'RED: exact-candidate DEV photograph receipt mode is not 600\n'
    failed=1
  fi
  if [ "$(_dev_stamp_file_owner "$receipt" || true)" != "$(id -u)" ]; then
    printf 'RED: exact-candidate DEV photograph receipt has another owner\n'
    failed=1
  fi
  dev_stamp_expected_binding_is_complete || failed=1

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*) key="${line%%=*}" ;;
      *) printf 'RED: DEV photograph receipt has an invalid line\n'; failed=1; continue ;;
    esac
    if ! _dev_stamp_key_is_known "$key"; then
      printf 'RED: DEV photograph receipt has an unknown key\n'
      failed=1
    fi
  done <"$receipt"

  while IFS= read -r required; do
    value="$(dev_stamp_receipt_get "$receipt" "$required" || true)"
    if [ -z "$value" ]; then
      printf 'RED: DEV photograph receipt has a missing or duplicate required key\n'
      failed=1
    fi
  done <<EOF
$(_dev_stamp_required_keys)
EOF

  [ "$(dev_stamp_receipt_get "$receipt" receipt_version || true)" = "$LASTDB_DEV_STAMP_RECEIPT_VERSION" ] \
    || { printf 'RED: DEV photograph receipt version is not 2\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" verdict || true)" = "GREEN" ] \
    || { printf 'RED: DEV photograph receipt verdict is not GREEN\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" loom_execution_id || true)" = "${LOOM_EXEC_ID:-}" ] \
    || { printf 'RED: DEV photograph receipt belongs to another Loom execution\n'; failed=1; }

  for key in source_git_oid lastdbd_path lastdb_path lastdbd_sha256 lastdb_sha256 lastdbd_version lastdb_version; do
    value="$(dev_stamp_receipt_get "$receipt" "$key" || true)"
    expected="$(_dev_stamp_expected_value "$key" || true)"
    if [ -z "$expected" ] || [ "$value" != "$expected" ]; then
      printf 'RED: DEV photograph receipt candidate binding does not match Loom\n'
      failed=1
    fi
  done
  case "$(dev_stamp_receipt_get "$receipt" source_git_oid || true)" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph receipt has an invalid source Git OID\n'; failed=1 ;;
  esac
  expected="${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}"
  [ "${#expected}" -eq 40 ] \
    || { printf 'RED: expected source Git OID is not full length\n'; failed=1; }
  case "$(dev_stamp_receipt_get "$receipt" lastdbd_sha256 || true)" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph receipt has an invalid daemon SHA-256\n'; failed=1 ;;
  esac
  case "$(dev_stamp_receipt_get "$receipt" lastdb_sha256 || true)" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph receipt has an invalid CLI SHA-256\n'; failed=1 ;;
  esac
  expected="${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}"
  [ "${#expected}" -eq 64 ] \
    || { printf 'RED: expected daemon SHA-256 is not full length\n'; failed=1; }
  expected="${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}"
  [ "${#expected}" -eq 64 ] \
    || { printf 'RED: expected CLI SHA-256 is not full length\n'; failed=1; }

  if ! dev_stamp_api_is_dev "$(dev_stamp_receipt_get "$receipt" api_url || true)"; then
    printf 'RED: DEV photograph receipt does not name the exact DEV API\n'
    failed=1
  fi

  home="$(dev_stamp_receipt_get "$receipt" home || true)"
  phome="$(dev_stamp_receipt_get "$receipt" primary_home || true)"
  if [ "$phome" != "$(_dev_stamp_real_maybe_absent "$primary")" ]; then
    printf 'RED: DEV photograph receipt names another primary home\n'
    failed=1
  fi
  if ! _dev_stamp_paths_do_not_overlap "$home" "$phome"; then
    printf 'RED: DEV photograph home overlaps the live primary\n'
    failed=1
  fi

  counter="$(dev_stamp_receipt_get "$receipt" counter || true)"
  cas_counter="$(dev_stamp_receipt_get "$receipt" cas_counter || true)"
  case "$counter" in ''|*[!0-9]*|0) printf 'RED: DEV photograph counter is not positive\n'; failed=1 ;; esac
  case "$cas_counter" in ''|*[!0-9]*|0) printf 'RED: DEV photograph CAS counter is not positive\n'; failed=1 ;; esac
  [ "$counter" = "$cas_counter" ] \
    || { printf 'RED: DEV photograph CAS counter differs from the committed counter\n'; failed=1; }
  case "$(dev_stamp_receipt_get "$receipt" manifest_sha256 || true)" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph manifest SHA-256 is invalid\n'; failed=1 ;;
  esac
  value="$(dev_stamp_receipt_get "$receipt" manifest_sha256 || true)"
  [ "${#value}" -eq 64 ] \
    || { printf 'RED: DEV photograph manifest SHA-256 is not full length\n'; failed=1; }
  [ -n "$(dev_stamp_receipt_get "$receipt" latest_key || true)" ] \
    || { printf 'RED: DEV photograph latest key is absent\n'; failed=1; }

  committed_at="$(dev_stamp_receipt_get "$receipt" committed_at || true)"
  committed_epoch="$(dev_stamp_receipt_get "$receipt" committed_epoch || true)"
  if ! _dev_stamp_time_is_valid "$committed_at" "$committed_epoch"; then
    printf 'RED: DEV photograph receipt time is invalid, stale, or in the future\n'
    failed=1
  fi

  for key in fresh_device_id production_cloud_config_absent production_cloud_residue_absent \
    production_presence_cache_absent production_manifest_cache_absent copied_session_absent \
    identity_preserved bootstrap_preserved; do
    [ "$(dev_stamp_receipt_get "$receipt" "$key" || true)" = "true" ] \
      || { printf 'RED: DEV photograph isolation proof is incomplete\n'; failed=1; }
  done

  [ "$failed" -eq 0 ]
}

# Write a v2 receipt from an already validated proof. The immutable candidate
# fields come only from the Loom environment. The rename is same-directory.
write_dev_stamp_receipt_v2() {
  local path="$1" primary_home="$2" cow_home="$3" counter="$4" cas_counter="$5"
  local manifest_sha256="$6" latest_key="$7" committed_at="$8" committed_epoch="$9"
  local dir base tmp

  dev_stamp_expected_binding_is_complete >/dev/null || return 1
  primary_home="$(_dev_stamp_real_maybe_absent "$primary_home")" || return 1
  cow_home="$(_dev_stamp_real_maybe_absent "$cow_home")" || return 1
  _dev_stamp_paths_do_not_overlap "$cow_home" "$primary_home" || return 1
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(umask 077; mktemp "$dir/.${base}.tmp.XXXXXX")" || return 1
  if ! (umask 077; {
    printf 'receipt_version=%s\n' "$LASTDB_DEV_STAMP_RECEIPT_VERSION"
    printf 'verdict=GREEN\n'
    printf 'loom_execution_id=%s\n' "$LOOM_EXEC_ID"
    printf 'source_git_oid=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID"
    printf 'lastdbd_path=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH"
    printf 'lastdb_path=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH"
    printf 'lastdbd_sha256=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256"
    printf 'lastdb_sha256=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256"
    printf 'lastdbd_version=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION"
    printf 'lastdb_version=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION"
    printf 'api_url=%s\n' "$LASTDB_DEV_BACKUP_API_URL_DEFAULT"
    printf 'home=%s\n' "$cow_home"
    printf 'primary_home=%s\n' "$primary_home"
    printf 'counter=%s\n' "$counter"
    printf 'cas_counter=%s\n' "$cas_counter"
    printf 'manifest_sha256=%s\n' "$manifest_sha256"
    printf 'latest_key=%s\n' "$latest_key"
    printf 'committed_at=%s\n' "$committed_at"
    printf 'committed_epoch=%s\n' "$committed_epoch"
    printf 'fresh_device_id=true\n'
    printf 'production_cloud_config_absent=true\n'
    printf 'production_cloud_residue_absent=true\n'
    printf 'production_presence_cache_absent=true\n'
    printf 'production_manifest_cache_absent=true\n'
    printf 'copied_session_absent=true\n'
    printf 'identity_preserved=true\n'
    printf 'bootstrap_preserved=true\n'
  } >"$tmp"; chmod 600 "$tmp") ; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  receipt="$(dev_stamp_receipt_path)"
  if ! assert_dev_photograph_stamp_ok "$receipt"; then
    printf 'VERDICT: RED\n'
    printf 'REASON: exact-candidate DEV photograph proof failed\n'
    exit 1
  fi
  printf 'VERDICT: GREEN\n'
  printf 'SUMMARY: exact-candidate DEV photograph receipt is valid\n'
fi
