#!/usr/bin/env bash
# Exact-candidate DEV photograph receipt gate for lastdb-safe-upgrade.
# Source this file for its functions. Direct execution validates one receipt.

# A receipt can authorize a live cutover only when it names the exact Loom
# execution, source commit, daemon bytes, CLI bytes, and isolated DEV result.

LASTDB_DEV_BACKUP_API_URL_DEFAULT="https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com"
LASTDB_PROD_BACKUP_API_HOST="jdsx4ixk2i.execute-api.us-east-1.amazonaws.com"
LASTDB_DEV_STAMP_RECEIPT_VERSION="4"
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
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

_dev_stamp_file_owner() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
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
clone_source
counter
cas_counter
manifest_sha256
cloud_db_hash
restore_manifest_sha256
restore_db_hash
restore_mode
restore_source_scope_verified
restore_cloud_sync_off
restore_report_sha256
manifest_key
latest_key
user_hash
manifest_cache
report_top_level
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
cleanup_retention
cleanup_handoff
EOF
}

_dev_stamp_key_is_known() {
  case "$1" in
    receipt_version|verdict|loom_execution_id|source_git_oid|lastdbd_path|lastdb_path|\
    lastdbd_sha256|lastdb_sha256|lastdbd_version|lastdb_version|api_url|home|\
    primary_home|clone_source|counter|cas_counter|manifest_sha256|cloud_db_hash|\
    restore_manifest_sha256|restore_db_hash|restore_mode|restore_source_scope_verified|\
    restore_cloud_sync_off|restore_report_sha256|manifest_key|latest_key|user_hash|\
    manifest_cache|report_top_level|committed_at|committed_epoch|\
    fresh_device_id|production_cloud_config_absent|\
    production_cloud_residue_absent|production_presence_cache_absent|\
    production_manifest_cache_absent|copied_session_absent|identity_preserved|\
    bootstrap_preserved|cleanup_retention|cleanup_handoff) return 0 ;;
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

# Validate one v4 receipt. Every failure prints a fixed RED reason. Receipt
# values do not reach output because a path or cloud key can contain secrets.
assert_dev_photograph_stamp_ok() {
  local receipt="${1:-$(dev_stamp_receipt_path)}"
  local primary="${2:-${LASTDB_HOME:-$HOME/.lastdb}}"
  local clone_source="${3:-${LASTDB_SAFE_UPGRADE_EXPECTED_CLONE_SOURCE:-}}"
  local require_retention="${4:-0}"
  local failed=0 line key required value expected
  local mode home phome counter cas_counter manifest_sha256 cloud_db_hash manifest_key latest_key
  local user_hash manifest_cache
  local expected_manifest_cache committed_at committed_epoch stored_clone real_clone
  local restore_report restore_report_sha256 restore_report_bytes

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
    || { printf 'RED: DEV photograph receipt version is not 4\n'; failed=1; }
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

  receipt_api_url="$(dev_stamp_receipt_get "$receipt" api_url || true)"
  if ! dev_stamp_api_is_dev "$receipt_api_url"; then
    # The dev check is exact equality, so it already refuses the production
    # host along with everything else — the refusal is not what changes here.
    # What changes is what the operator is told. "does not name the exact DEV
    # API" is the same sentence for a typo, an empty field, and a receipt that
    # names the PRODUCTION backup API, and only the last of those means the
    # photograph ran against Tom's real backup home. Say which one it is.
    # papercut-lastdb-safe-upgrade-unwired-guard-functions-20260907
    if dev_stamp_api_is_prod "$receipt_api_url"; then
      printf 'RED: DEV photograph receipt names the PRODUCTION backup API\n'
    else
      printf 'RED: DEV photograph receipt does not name the exact DEV API\n'
    fi
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
  stored_clone="$(dev_stamp_receipt_get "$receipt" clone_source || true)"
  real_clone=""
  if [ -n "$clone_source" ] && [ -d "$clone_source" ] && [ ! -L "$clone_source" ]; then
    real_clone="$(_dev_stamp_real_dir "$clone_source" || true)"
  fi
  if [ -z "$real_clone" ] || [ "$stored_clone" != "$real_clone" ] \
      || [ ! -d "$real_clone/data" ] || [ -L "$real_clone/data" ] \
      || [ ! -f "$real_clone/.safe-upgrade/complete" ] \
      || [ -L "$real_clone/.safe-upgrade/complete" ] \
      || ! grep -qx 'kind=trial' "$real_clone/.safe-upgrade/complete" \
      || ! _dev_stamp_paths_do_not_overlap "$real_clone" "$phome"; then
    printf 'RED: DEV photograph receipt does not name this run\047s fresh trial copy\n'
    failed=1
  fi

  counter="$(dev_stamp_receipt_get "$receipt" counter || true)"
  cas_counter="$(dev_stamp_receipt_get "$receipt" cas_counter || true)"
  case "$counter" in ''|*[!0-9]*|0) printf 'RED: DEV photograph counter is not positive\n'; failed=1 ;; esac
  case "$cas_counter" in ''|*[!0-9]*|0) printf 'RED: DEV photograph CAS counter is not positive\n'; failed=1 ;; esac
  [ "$counter" = "$cas_counter" ] \
    || { printf 'RED: DEV photograph CAS counter differs from the committed counter\n'; failed=1; }
  manifest_sha256="$(dev_stamp_receipt_get "$receipt" manifest_sha256 || true)"
  case "$manifest_sha256" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph manifest SHA-256 is invalid\n'; failed=1 ;;
  esac
  [ "${#manifest_sha256}" -eq 64 ] \
    || { printf 'RED: DEV photograph manifest SHA-256 is not full length\n'; failed=1; }
  manifest_key="$(dev_stamp_receipt_get "$receipt" manifest_key || true)"
  latest_key="$(dev_stamp_receipt_get "$receipt" latest_key || true)"
  cloud_db_hash="$(dev_stamp_receipt_get "$receipt" cloud_db_hash || true)"
  user_hash="$(dev_stamp_receipt_get "$receipt" user_hash || true)"
  case "$user_hash" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph user hash is invalid\n'; failed=1 ;;
  esac
  [ "${#user_hash}" -eq 32 ] \
    || { printf 'RED: DEV photograph user hash is not full length\n'; failed=1; }
  case "$cloud_db_hash" in
    *[!0-9a-f]*|'') printf 'RED: DEV photograph cloud DB hash is invalid\n'; failed=1 ;;
  esac
  [ "${#cloud_db_hash}" -eq 64 ] \
    || { printf 'RED: DEV photograph cloud DB hash is not full length\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" restore_manifest_sha256 || true)" = "$manifest_sha256" ] \
    && [ "$(dev_stamp_receipt_get "$receipt" restore_db_hash || true)" = "$cloud_db_hash" ] \
    && [ "$(dev_stamp_receipt_get "$receipt" restore_mode || true)" = "replay_tail" ] \
    && [ "$(dev_stamp_receipt_get "$receipt" restore_source_scope_verified || true)" = "true" ] \
    && [ "$(dev_stamp_receipt_get "$receipt" restore_cloud_sync_off || true)" = "true" ] \
    || { printf 'RED: DEV photograph receipt lacks exact source-free restore proof\n'; failed=1; }
  [ -n "$cloud_db_hash" ] && [ "$latest_key" = "$cloud_db_hash/backup/latest" ] \
    || { printf 'RED: DEV photograph latest key does not match its cloud DB hash\n'; failed=1; }
  [ -n "$cloud_db_hash" ] && [ -n "$manifest_sha256" ] \
    && [ "$manifest_key" = "$cloud_db_hash/backup/manifests/$manifest_sha256" ] \
    || { printf 'RED: DEV photograph manifest key does not match its cloud DB hash and digest\n'; failed=1; }

  restore_report="${receipt}.restore.json"
  restore_report_sha256="$(dev_stamp_receipt_get "$receipt" restore_report_sha256 || true)"
  case "$restore_report_sha256" in
    *[!0-9a-f]*|'') printf 'RED: DEV restore report digest is invalid\n'; failed=1 ;;
  esac
  [ "${#restore_report_sha256}" -eq 64 ] \
    || { printf 'RED: DEV restore report digest is not full length\n'; failed=1; }
  if [ ! -f "$restore_report" ] || [ -L "$restore_report" ] \
      || [ "$(_dev_stamp_file_mode "$restore_report" || true)" != "600" ] \
      || [ "$(_dev_stamp_file_owner "$restore_report" || true)" != "$(id -u)" ]; then
    printf 'RED: DEV restore report evidence is absent or unsafe\n'
    failed=1
  else
    restore_report_bytes="$(wc -c <"$restore_report" | tr -d ' ')"
    case "$restore_report_bytes" in
      ''|*[!0-9]*) restore_report_bytes=4097 ;;
    esac
    if [ "$restore_report_bytes" -gt 4096 ] \
        || [ "$(dev_stamp_sha256_file "$restore_report" || true)" != "$restore_report_sha256" ] \
        || ! jq -e --arg manifest "$manifest_sha256" --arg db_hash "$cloud_db_hash" '
          type == "object"
          and (keys | sort) == ["cloud_sync_off","db_hash","manifest_sha256","ok", "remote_read_only","restore_mode","source_scope_verified"]
          and .ok == true
          and .manifest_sha256 == $manifest
          and .db_hash == $db_hash
          and .restore_mode == "replay_tail"
          and .remote_read_only == true
          and .source_scope_verified == true
          and .cloud_sync_off == true
        ' "$restore_report" >/dev/null 2>&1; then
      printf 'RED: DEV restore report evidence differs from the exact source-free result\n'
      failed=1
    fi
  fi

  manifest_cache="$(dev_stamp_receipt_get "$receipt" manifest_cache || true)"
  expected_manifest_cache=""
  case "$home" in
    /*) expected_manifest_cache="$(_dev_stamp_real_maybe_absent "$home/laststore_backup_manifest.json" || true)" ;;
  esac
  [ -n "$expected_manifest_cache" ] && [ "$manifest_cache" = "$expected_manifest_cache" ] \
    || { printf 'RED: DEV photograph manifest cache does not match its isolated home\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" report_top_level || true)" = "true" ] \
    || { printf 'RED: DEV photograph report was not top-level\n'; failed=1; }

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

  case "$(dev_stamp_receipt_get "$receipt" cleanup_retention || true)" in
    required)
      [ "$(dev_stamp_receipt_get "$receipt" cleanup_handoff || true)" = "${receipt}.cloud-cleanup.json" ] \
        && python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/dev-photograph-cleanup-handoff.py" \
          check --receipt "$receipt" >/dev/null 2>&1 \
        || { printf 'RED: stopped DEV cleanup handoff is absent or differs\n'; failed=1; } ;;
    not_requested)
      [ "$require_retention" = "0" ] \
        && [ "$(dev_stamp_receipt_get "$receipt" cleanup_handoff || true)" = "none" ] \
        || { printf 'RED: this upgrade requires retained DEV cleanup access\n'; failed=1; } ;;
    *) printf 'RED: DEV cleanup retention contract is invalid\n'; failed=1 ;;
  esac
  [ "$failed" -eq 0 ]
}

# Write a v4 receipt from an already validated snapshot and restore. The immutable candidate
# fields come only from the Loom environment. The rename is same-directory.
write_dev_stamp_receipt_v4() {
  local path="$1" primary_home="$2" cow_home="$3" counter="$4" cas_counter="$5"
  local manifest_sha256="$6" cloud_db_hash="$7" manifest_key="$8" latest_key="$9"
  local user_hash="${10}" manifest_cache="${11}" committed_at="${12}" committed_epoch="${13}"
  local clone_source="${14}" restore_report_sha256="${15}" retain="${16:-0}"
  local dir base tmp

  dev_stamp_expected_binding_is_complete >/dev/null || return 1
  primary_home="$(_dev_stamp_real_maybe_absent "$primary_home")" || return 1
  cow_home="$(_dev_stamp_real_maybe_absent "$cow_home")" || return 1
  _dev_stamp_paths_do_not_overlap "$cow_home" "$primary_home" || return 1
  [ -d "$clone_source/data" ] && [ ! -L "$clone_source" ] \
    && [ ! -L "$clone_source/data" ] \
    && [ -f "$clone_source/.safe-upgrade/complete" ] \
    && [ ! -L "$clone_source/.safe-upgrade/complete" ] \
    && grep -qx 'kind=trial' "$clone_source/.safe-upgrade/complete" || return 1
  clone_source="$(_dev_stamp_real_dir "$clone_source")" || return 1
  _dev_stamp_paths_do_not_overlap "$clone_source" "$primary_home" || return 1
  [ -f "${path}.restore.json" ] && [ ! -L "${path}.restore.json" ] \
    && [ "$(dev_stamp_sha256_file "${path}.restore.json" || true)" = "$restore_report_sha256" ] \
    || return 1
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
    printf 'clone_source=%s\n' "$clone_source"
    printf 'counter=%s\n' "$counter"
    printf 'cas_counter=%s\n' "$cas_counter"
    printf 'manifest_sha256=%s\n' "$manifest_sha256"
    printf 'cloud_db_hash=%s\n' "$cloud_db_hash"
    printf 'restore_manifest_sha256=%s\n' "$manifest_sha256"
    printf 'restore_db_hash=%s\n' "$cloud_db_hash"
    printf 'restore_mode=replay_tail\n'
    printf 'restore_source_scope_verified=true\n'
    printf 'restore_cloud_sync_off=true\n'
    printf 'restore_report_sha256=%s\n' "$restore_report_sha256"
    printf 'manifest_key=%s\n' "$manifest_key"
    printf 'latest_key=%s\n' "$latest_key"
    printf 'user_hash=%s\n' "$user_hash"
    printf 'manifest_cache=%s\n' "$manifest_cache"
    printf 'report_top_level=true\n'
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
    if [ "$retain" = "1" ]; then
      printf 'cleanup_retention=required\n'
      printf 'cleanup_handoff=%s.cloud-cleanup.json\n' "$path"
    else
      printf 'cleanup_retention=not_requested\n'
      printf 'cleanup_handoff=none\n'
    fi
  } >"$tmp"; chmod 600 "$tmp") ; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- Receipt v5: format 7 V2 DEV restore proof --------------------------------
# A format 7 home has no V1 photograph. dev-v2-restore-proof.sh backs up a clone
# of the trial home to DEV with `backup-v2` and restores that exact commit into
# a source-free home. Same receipt root and exact path as v4: one Loom execution
# has one route, so it has one receipt. A v4 receipt never satisfies this gate.
LASTDB_DEV_V2_RECEIPT_VERSION="5"
LASTDB_DEV_V2_PROOF_KIND="format7-v2-dev-restore"
_DEV_V2_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

_dev_v2_required_keys() {
  cat <<'EOF'
receipt_version
verdict
proof_kind
loom_execution_id
source_git_oid
lastdbd_path
lastdb_path
lastdbd_sha256
lastdb_sha256
lastdbd_version
lastdb_version
api_url
environment
home
primary_home
clone_source
user_hash
source_home
stream_id
account_generation
commit_id
commit_sha256
backup_kind
restore_commit_sha256
restore_native_files
restore_native_bytes
restore_known_keys
restore_report_sha256
restore_file_dependencies_verified
restore_cloud_off
restore_identity_matches
source_strict_stop
restored_strict_stop
identity_preserved
seed_cloud_state_absent
committed_at
committed_epoch
cloud_cleanup
EOF
}

_dev_v2_flag_keys() {
  printf '%s\n' restore_file_dependencies_verified restore_cloud_off \
    restore_identity_matches source_strict_stop restored_strict_stop \
    identity_preserved seed_cloud_state_absent
}

_dev_v2_matches() {
  printf '%s' "$1" | grep -Eq "$2"
}

# Validate one v5 receipt. Like v4, a failure prints a fixed RED reason and no
# receipt value: a path or a cloud identifier must not reach a shared log.
assert_dev_v2_restore_stamp_ok() {
  local receipt="${1:-$(dev_stamp_receipt_path)}"
  local primary="${2:-${LASTDB_HOME:-$HOME/.lastdb}}"
  local clone_source="${3:-${LASTDB_SAFE_UPGRADE_EXPECTED_CLONE_SOURCE:-}}"
  local failed=0 line key value expected required_keys
  local home phome stored_clone real_clone user_hash commit_sha256 native_files native_bytes known_keys
  local evidence evidence_sha256 evidence_bytes receipt_api_url

  if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
    printf 'RED: exact-candidate V2 DEV restore receipt is absent or unsafe\n'
    return 1
  fi
  [ "$(_dev_stamp_file_mode "$receipt" || true)" = "600" ] \
    || { printf 'RED: V2 DEV restore receipt mode is not 600\n'; failed=1; }
  [ "$(_dev_stamp_file_owner "$receipt" || true)" = "$(id -u)" ] \
    || { printf 'RED: V2 DEV restore receipt has another owner\n'; failed=1; }
  dev_stamp_expected_binding_is_complete || failed=1

  required_keys="$(_dev_v2_required_keys)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*) key="${line%%=*}" ;;
      *) printf 'RED: V2 DEV restore receipt has an invalid line\n'; failed=1; continue ;;
    esac
    printf '%s\n' "$required_keys" | grep -qx "$key" \
      || { printf 'RED: V2 DEV restore receipt has an unknown key\n'; failed=1; }
  done <"$receipt"
  while IFS= read -r key; do
    [ -n "$(dev_stamp_receipt_get "$receipt" "$key" || true)" ] \
      || { printf 'RED: V2 DEV restore receipt has a missing or duplicate required key\n'; failed=1; }
  done <<EOF
$required_keys
EOF

  [ "$(dev_stamp_receipt_get "$receipt" receipt_version || true)" = "$LASTDB_DEV_V2_RECEIPT_VERSION" ] \
    || { printf 'RED: V2 DEV restore receipt version is not 5\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" verdict || true)" = "GREEN" ] \
    || { printf 'RED: V2 DEV restore receipt verdict is not GREEN\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" proof_kind || true)" = "$LASTDB_DEV_V2_PROOF_KIND" ] \
    || { printf 'RED: V2 DEV restore receipt is another proof kind\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" loom_execution_id || true)" = "${LOOM_EXEC_ID:-}" ] \
    || { printf 'RED: V2 DEV restore receipt belongs to another Loom execution\n'; failed=1; }

  for key in source_git_oid lastdbd_path lastdb_path lastdbd_sha256 lastdb_sha256 lastdbd_version lastdb_version; do
    value="$(dev_stamp_receipt_get "$receipt" "$key" || true)"
    expected="$(_dev_stamp_expected_value "$key" || true)"
    if [ -z "$expected" ] || [ "$value" != "$expected" ]; then
      printf 'RED: V2 DEV restore receipt candidate binding does not match Loom\n'
      failed=1
    fi
  done
  _dev_v2_matches "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" '^[0-9a-f]{40}$' \
    || { printf 'RED: expected source Git OID is not full length\n'; failed=1; }
  _dev_v2_matches "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}" '^[0-9a-f]{64}$' \
    && _dev_v2_matches "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}" '^[0-9a-f]{64}$' \
    || { printf 'RED: expected candidate SHA-256 is not full length\n'; failed=1; }

  receipt_api_url="$(dev_stamp_receipt_get "$receipt" api_url || true)"
  if ! dev_stamp_api_is_dev "$receipt_api_url"; then
    if dev_stamp_api_is_prod "$receipt_api_url"; then
      printf 'RED: V2 DEV restore receipt names the PRODUCTION backup API\n'
    else
      printf 'RED: V2 DEV restore receipt does not name the exact DEV API\n'
    fi
    failed=1
  fi
  [ "$(dev_stamp_receipt_get "$receipt" environment || true)" = "dev" ] \
    || { printf 'RED: V2 DEV restore receipt does not name the DEV environment\n'; failed=1; }

  home="$(dev_stamp_receipt_get "$receipt" home || true)"
  phome="$(dev_stamp_receipt_get "$receipt" primary_home || true)"
  [ "$phome" = "$(_dev_stamp_real_maybe_absent "$primary")" ] \
    || { printf 'RED: V2 DEV restore receipt names another primary home\n'; failed=1; }
  _dev_stamp_paths_do_not_overlap "$home" "$phome" \
    || { printf 'RED: V2 DEV restore home overlaps the live primary\n'; failed=1; }
  stored_clone="$(dev_stamp_receipt_get "$receipt" clone_source || true)"
  real_clone=""
  if [ -n "$clone_source" ] && [ -d "$clone_source" ] && [ ! -L "$clone_source" ]; then
    real_clone="$(_dev_stamp_real_dir "$clone_source" || true)"
  fi
  if [ -z "$real_clone" ] || [ "$stored_clone" != "$real_clone" ] \
      || [ ! -d "$real_clone/data" ] || [ -L "$real_clone/data" ] \
      || [ ! -f "$real_clone/.safe-upgrade/complete" ] \
      || [ -L "$real_clone/.safe-upgrade/complete" ] \
      || ! grep -qx 'kind=trial' "$real_clone/.safe-upgrade/complete" \
      || ! _dev_stamp_paths_do_not_overlap "$real_clone" "$phome"; then
    printf 'RED: V2 DEV restore receipt does not name this run\047s fresh trial copy\n'
    failed=1
  fi

  user_hash="$(dev_stamp_receipt_get "$receipt" user_hash || true)"
  _dev_v2_matches "$user_hash" '^[0-9a-f]{32}$' \
    || { printf 'RED: V2 DEV restore user hash is invalid\n'; failed=1; }
  for key in source_home stream_id commit_id; do
    _dev_v2_matches "$(dev_stamp_receipt_get "$receipt" "$key" || true)" "$_DEV_V2_UUID_RE" \
      || { printf 'RED: V2 DEV restore receipt has an invalid backup identifier\n'; failed=1; }
  done
  _dev_v2_matches "$(dev_stamp_receipt_get "$receipt" account_generation || true)" '^[0-9]+$' \
    || { printf 'RED: V2 DEV restore account generation is invalid\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" backup_kind || true)" = "snapshot" ] \
    || { printf 'RED: V2 DEV restore backup is not a snapshot\n'; failed=1; }
  commit_sha256="$(dev_stamp_receipt_get "$receipt" commit_sha256 || true)"
  _dev_v2_matches "$commit_sha256" '^[0-9a-f]{64}$' \
    || { printf 'RED: V2 DEV restore commit SHA-256 is invalid\n'; failed=1; }
  [ "$(dev_stamp_receipt_get "$receipt" restore_commit_sha256 || true)" = "$commit_sha256" ] \
    || { printf 'RED: V2 DEV restore did not restore the published commit\n'; failed=1; }
  native_files="$(dev_stamp_receipt_get "$receipt" restore_native_files || true)"
  native_bytes="$(dev_stamp_receipt_get "$receipt" restore_native_bytes || true)"
  known_keys="$(dev_stamp_receipt_get "$receipt" restore_known_keys || true)"
  for value in "$native_files" "$native_bytes" "$known_keys"; do
    _dev_v2_matches "$value" '^[1-9][0-9]*$' \
      || { printf 'RED: V2 DEV restore count is not positive\n'; failed=1; }
  done
  while IFS= read -r key; do
    [ "$(dev_stamp_receipt_get "$receipt" "$key" || true)" = "true" ] \
      || { printf 'RED: V2 DEV restore isolation or restore proof is incomplete\n'; failed=1; }
  done <<EOF
$(_dev_v2_flag_keys)
EOF
  # This release has no V2 delete command. The DEV stream stays.
  [ "$(dev_stamp_receipt_get "$receipt" cloud_cleanup || true)" = "none" ] \
    || { printf 'RED: V2 DEV restore cleanup contract is invalid\n'; failed=1; }

  evidence="${receipt}.restore.json"
  evidence_sha256="$(dev_stamp_receipt_get "$receipt" restore_report_sha256 || true)"
  _dev_v2_matches "$evidence_sha256" '^[0-9a-f]{64}$' \
    || { printf 'RED: V2 DEV restore report digest is invalid\n'; failed=1; }
  if [ ! -f "$evidence" ] || [ -L "$evidence" ] \
      || [ "$(_dev_stamp_file_mode "$evidence" || true)" != "600" ] \
      || [ "$(_dev_stamp_file_owner "$evidence" || true)" != "$(id -u)" ]; then
    printf 'RED: V2 DEV restore report evidence is absent or unsafe\n'
    failed=1
  else
    evidence_bytes="$(wc -c <"$evidence" | tr -d ' ')"
    case "$evidence_bytes" in ''|*[!0-9]*) evidence_bytes=4097 ;; esac
    if [ "$evidence_bytes" -gt 4096 ] \
        || [ "$(dev_stamp_sha256_file "$evidence" || true)" != "$evidence_sha256" ] \
        || ! jq -e --arg commit "$commit_sha256" --arg files "$native_files" \
          --arg bytes "$native_bytes" --arg keys "$known_keys" '
          type == "object"
          and (keys | sort) == ["cloud_off","commit_sha256","file_dependencies_verified","known_keys","native_bytes","native_files"]
          and .commit_sha256 == $commit
          and .file_dependencies_verified == true
          and .cloud_off == true
          and (.native_files | tostring) == $files
          and (.native_bytes | tostring) == $bytes
          and (.known_keys | tostring) == $keys
        ' "$evidence" >/dev/null 2>&1; then
      printf 'RED: V2 DEV restore report evidence differs from the receipt\n'
      failed=1
    fi
  fi

  _dev_stamp_time_is_valid "$(dev_stamp_receipt_get "$receipt" committed_at || true)" \
    "$(dev_stamp_receipt_get "$receipt" committed_epoch || true)" \
    || { printf 'RED: V2 DEV restore receipt time is invalid, stale, or in the future\n'; failed=1; }
  [ "$failed" -eq 0 ]
}

# Write a v5 receipt from an already validated backup, restore and key read.
# The candidate fields come only from the Loom environment. The evidence file
# must already exist beside the receipt. The rename is same-directory.
write_dev_v2_restore_receipt() {
  local path="$1" primary_home="$2" proof_home="$3" clone_source="$4" user_hash="$5"
  local source_home="$6" stream_id="$7" generation="$8" commit_id="$9" commit_sha256="${10}"
  local native_files="${11}" native_bytes="${12}" known_keys="${13}" evidence_sha256="${14}"
  local committed_at="${15}" committed_epoch="${16}"
  local dir base tmp key

  dev_stamp_expected_binding_is_complete >/dev/null || return 1
  primary_home="$(_dev_stamp_real_maybe_absent "$primary_home")" || return 1
  proof_home="$(_dev_stamp_real_maybe_absent "$proof_home")" || return 1
  _dev_stamp_paths_do_not_overlap "$proof_home" "$primary_home" || return 1
  [ -d "$clone_source/data" ] && [ ! -L "$clone_source" ] \
    && [ ! -L "$clone_source/data" ] \
    && [ -f "$clone_source/.safe-upgrade/complete" ] \
    && [ ! -L "$clone_source/.safe-upgrade/complete" ] \
    && grep -qx 'kind=trial' "$clone_source/.safe-upgrade/complete" || return 1
  clone_source="$(_dev_stamp_real_dir "$clone_source")" || return 1
  _dev_stamp_paths_do_not_overlap "$clone_source" "$primary_home" || return 1
  [ -f "${path}.restore.json" ] && [ ! -L "${path}.restore.json" ] \
    && [ "$(dev_stamp_sha256_file "${path}.restore.json" || true)" = "$evidence_sha256" ] \
    || return 1
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(umask 077; mktemp "$dir/.${base}.tmp.XXXXXX")" || return 1
  if ! (umask 077; {
    printf 'receipt_version=%s\n' "$LASTDB_DEV_V2_RECEIPT_VERSION"
    printf 'verdict=GREEN\n'
    printf 'proof_kind=%s\n' "$LASTDB_DEV_V2_PROOF_KIND"
    printf 'loom_execution_id=%s\n' "$LOOM_EXEC_ID"
    printf 'source_git_oid=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID"
    printf 'lastdbd_path=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH"
    printf 'lastdb_path=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH"
    printf 'lastdbd_sha256=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256"
    printf 'lastdb_sha256=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256"
    printf 'lastdbd_version=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION"
    printf 'lastdb_version=%s\n' "$LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION"
    printf 'api_url=%s\n' "$LASTDB_DEV_BACKUP_API_URL_DEFAULT"
    printf 'environment=dev\n'
    printf 'home=%s\n' "$proof_home"
    printf 'primary_home=%s\n' "$primary_home"
    printf 'clone_source=%s\n' "$clone_source"
    printf 'user_hash=%s\n' "$user_hash"
    printf 'source_home=%s\n' "$source_home"
    printf 'stream_id=%s\n' "$stream_id"
    printf 'account_generation=%s\n' "$generation"
    printf 'commit_id=%s\n' "$commit_id"
    printf 'commit_sha256=%s\n' "$commit_sha256"
    printf 'backup_kind=snapshot\n'
    printf 'restore_commit_sha256=%s\n' "$commit_sha256"
    printf 'restore_native_files=%s\n' "$native_files"
    printf 'restore_native_bytes=%s\n' "$native_bytes"
    printf 'restore_known_keys=%s\n' "$known_keys"
    printf 'restore_report_sha256=%s\n' "$evidence_sha256"
    _dev_v2_flag_keys | while IFS= read -r key; do printf '%s=true\n' "$key"; done
    printf 'committed_at=%s\n' "$committed_at"
    printf 'committed_epoch=%s\n' "$committed_epoch"
    printf 'cloud_cleanup=none\n'
  } >"$tmp"; chmod 600 "$tmp"); then
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
  check=assert_dev_photograph_stamp_ok
  if [ "$(dev_stamp_receipt_get "$receipt" receipt_version 2>/dev/null || true)" = "$LASTDB_DEV_V2_RECEIPT_VERSION" ]; then
    check=assert_dev_v2_restore_stamp_ok
  fi
  if ! "$check" "$receipt"; then
    printf 'VERDICT: RED\n'
    printf 'REASON: exact-candidate DEV proof failed\n'
    exit 1
  fi
  printf 'VERDICT: GREEN\n'
  printf 'SUMMARY: exact-candidate DEV proof receipt is valid\n'
fi
