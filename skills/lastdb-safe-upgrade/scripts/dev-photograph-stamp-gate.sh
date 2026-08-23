#!/usr/bin/env bash
# DEV photograph-stamp gate for lastdb-safe-upgrade (Tom 2026-08-19).
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# Standing rule: never live-cutover a candidate lastdbd until an ephemeral/CoW
# copy of real data has uploaded a photograph to DEV (not the primary's
# production backup home) and CAS-flipped backup/latest. A mock object store
# is not DEV. Pointing the candidate at live ~/.lastdb is forbidden.
#
# Receipt keys (one KEY=VAL per line):
#   verdict=GREEN|RED
#   api_url=...
#   home=...          # ephemeral node home; must not be the live primary
#   primary_home=...
#   counter=...       # committed photograph counter (>=1)
#   committed_at=...  # RFC3339
#
# rc 0 = GREEN stamp usable for live; rc 1 = refuse live cutover.

# DEV Exemem API (us-west-2). Prod personal backup is a different host.
LASTDB_DEV_BACKUP_API_URL_DEFAULT="https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com"
LASTDB_PROD_BACKUP_API_HOST="jdsx4ixk2i.execute-api.us-east-1.amazonaws.com"

dev_stamp_receipt_path() {
  printf '%s\n' "${LASTDB_DEV_STAMP_RECEIPT:-$HOME/.local/state/last-stack/lastdb-safe-upgrade/dev-photograph-stamp.receipt}"
}

dev_stamp_receipt_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '$1==k {sub(/^[^=]+=/,""); print; exit}' "$file"
}

dev_stamp_api_is_prod() {
  case "$1" in
    *"${LASTDB_PROD_BACKUP_API_HOST}"*) return 0 ;;
  esac
  return 1
}

dev_stamp_api_is_dev() {
  case "$1" in
    *ygyu7ritx8.execute-api.us-west-2.amazonaws.com*) return 0 ;;
  esac
  return 1
}

# Realpath if possible; otherwise the given path.
_dev_stamp_real() {
  local p="$1"
  (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
}

# Validate a receipt. Prints human reasons to stdout (one per line, RED:/WARN:).
# rc 0 = OK; rc 1 = refuse live.
assert_dev_photograph_stamp_ok() {
  local receipt="${1:-$(dev_stamp_receipt_path)}"
  local primary="${2:-${LASTDB_HOME:-$HOME/.lastdb}}"
  local reasons=()
  local verdict api home phome counter

  if [ ! -f "$receipt" ]; then
    reasons+=("no DEV photograph stamp receipt at $receipt — boot the candidate on an ephemeral/CoW copy, upload the photograph to DEV, and record a GREEN stamp before live cutover")
  else
    verdict="$(dev_stamp_receipt_get "$receipt" verdict || true)"
    api="$(dev_stamp_receipt_get "$receipt" api_url || true)"
    home="$(dev_stamp_receipt_get "$receipt" home || true)"
    phome="$(dev_stamp_receipt_get "$receipt" primary_home || true)"
    counter="$(dev_stamp_receipt_get "$receipt" counter || true)"

    if [ "$verdict" != "GREEN" ]; then
      reasons+=("DEV photograph stamp verdict is '${verdict:-missing}' (need GREEN)")
    fi
    if [ -z "$api" ]; then
      reasons+=("DEV photograph stamp receipt has no api_url")
    elif dev_stamp_api_is_prod "$api"; then
      reasons+=("DEV photograph stamp api_url is the primary production backup host ($LASTDB_PROD_BACKUP_API_HOST) — CoW must not CAS production latest")
    elif ! dev_stamp_api_is_dev "$api"; then
      reasons+=("DEV photograph stamp api_url is not the DEV Exemem host (got ${api})")
    fi
    if [ -z "$home" ]; then
      reasons+=("DEV photograph stamp receipt has no ephemeral home")
    else
      local home_r primary_r
      home_r="$(_dev_stamp_real "$home")"
      primary_r="$(_dev_stamp_real "$primary")"
      if [ "$home_r" = "$primary_r" ]; then
        reasons+=("DEV photograph stamp home is the live primary ($home_r) — never point the candidate at ~/.lastdb")
      fi
    fi
    if [ -n "$phome" ]; then
      local phome_r primary_r
      phome_r="$(_dev_stamp_real "$phome")"
      primary_r="$(_dev_stamp_real "$primary")"
      if [ "$phome_r" != "$primary_r" ] && [ -d "$primary" ]; then
        printf 'WARN: receipt primary_home=%s differs from live %s\n' "$phome" "$primary"
      fi
    fi
    case "$counter" in
      ''|0) reasons+=("DEV photograph stamp has no committed counter (need CAS latest / committed snapshot >= 1)") ;;
      *[!0-9]*) reasons+=("DEV photograph stamp counter is not an integer: $counter") ;;
    esac
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

# Write a receipt. Does not treat prod api_url as GREEN even if asked.
write_dev_stamp_receipt() {
  local path="$1"
  local verdict="$2"
  local api_url="$3"
  local home="$4"
  local primary_home="$5"
  local counter="$6"
  local committed_at="${7:-}"
  local extra="${8:-}"

  if dev_stamp_api_is_prod "$api_url"; then
    verdict="RED"
  fi
  if [ "$verdict" = "GREEN" ] && ! dev_stamp_api_is_dev "$api_url"; then
    verdict="RED"
  fi
  mkdir -p "$(dirname "$path")"
  {
    printf 'verdict=%s\n' "$verdict"
    printf 'api_url=%s\n' "$api_url"
    printf 'home=%s\n' "$home"
    printf 'primary_home=%s\n' "$primary_home"
    printf 'counter=%s\n' "$counter"
    printf 'committed_at=%s\n' "${committed_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra"
    fi
  } >"$path"
}

# When sourced, do nothing else. When executed: check the receipt and exit.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  receipt="$(dev_stamp_receipt_path)"
  out=""
  rc=0
  set +e
  out="$(assert_dev_photograph_stamp_ok "$receipt" 2>&1)"
  rc=$?
  set -e
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "VERDICT: RED"
    echo "REASON: live cutover refused — DEV photograph stamp is missing or RED"
    exit 1
  fi
  echo "VERDICT: GREEN"
  echo "SUMMARY: DEV photograph stamp receipt is GREEN at $receipt"
  exit 0
fi
