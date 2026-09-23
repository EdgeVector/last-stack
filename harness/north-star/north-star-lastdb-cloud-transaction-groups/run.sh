#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-cloud-transaction-groups
# Offline terminal proof for cloud transaction groups.
# Reads the Fold pin-log contract. Does not open a LastDB home.
# Does not start a cloud cutover.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-cloud-transaction-groups
MODE="$(ns_mode)"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHECK="$HERE/check_contract.py"
PIN_REL="fold_db/crates/core/src/sync/engine/pin_log.rs"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/txn-group-proof.XXXXXX")"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

finish() {
  local verdict="$1" body="$2"
  if [ "$verdict" = FAIL ]; then
    ns_write_report "$SLUG" FAIL "$body" || true
    exit 1
  fi
  ns_write_report "$SLUG" "$verdict" "$body"
  exit 0
}

case "$MODE" in
  live|offline) ;;
  *)
    finish FAIL "The proof mode is invalid: $MODE."
    ;;
esac

if [ -n "${CLOUD_TRANSACTION_GROUPS_ALLOW_CUTOVER:-}" ]; then
  finish FAIL "This harness does not start a cloud cutover. Remove CLOUD_TRANSACTION_GROUPS_ALLOW_CUTOVER."
fi

refuse_primary() {
  local candidate="$1" link
  [ -n "$candidate" ] || return 0
  case "$candidate" in
    "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*)
      finish FAIL "The harness refuses a LastDB home path."
      ;;
  esac
  if [ -L "$candidate" ]; then
    link="$(readlink "$candidate")"
    case "$link" in
      "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*|*/.lastdb|*/.lastdb/*|*/.folddb|*/.folddb/*)
        finish FAIL "The harness refuses a LastDB home path."
        ;;
    esac
  fi
}

copy_pin_log() {
  local repo="$1" source_label="$2"
  refuse_primary "$repo"
  if [ -f "$repo/$PIN_REL" ]; then
    cp "$repo/$PIN_REL" "$TMP/pin_log.rs"
    printf '%s\n' "$source_label"
    return 0
  fi
  if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
    if ! git -C "$repo" show "HEAD:$PIN_REL" >"$TMP/pin_log.rs"; then
      finish FAIL "The Fold pin-log source is absent."
    fi
    printf '%s\n' "git:$repo:HEAD:$PIN_REL"
    return 0
  fi
  return 1
}

load_pin_log() {
  local explicit repo portal cache ws
  explicit="${CLOUD_TRANSACTION_GROUPS_PIN_LOG_FILE:-}"
  if [ -n "$explicit" ]; then
    refuse_primary "$explicit"
    [ -f "$explicit" ] || finish FAIL "The pin-log source file is absent."
    cp "$explicit" "$TMP/pin_log.rs"
    printf '%s\n' "$explicit"
    return 0
  fi

  repo="${FOLD_REPO:-}"
  if [ -n "$repo" ]; then
    copy_pin_log "$repo" "$repo/$PIN_REL" || finish FAIL "The Fold pin-log source is absent."
    return 0
  fi

  portal="$(ns_edgevector_workspace)/fold/.portal/cache"
  if [ -f "$portal" ]; then
    cache="$(tr -d '[:space:]' <"$portal")"
    refuse_primary "$cache"
    [ -d "$cache" ] || finish FAIL "The Fold portal cache is absent."
    if ! git --git-dir="$cache" show "HEAD:$PIN_REL" >"$TMP/pin_log.rs"; then
      finish FAIL "The Fold pin-log source is absent."
    fi
    printf '%s\n' "git:$cache:HEAD:$PIN_REL"
    return 0
  fi

  ws="$(ns_edgevector_workspace)/fold"
  copy_pin_log "$ws" "$ws/$PIN_REL" || finish FAIL "The Fold pin-log source is absent."
}

load_pin_log >"$TMP/source-label"
SOURCE_LABEL="$(sed -n '1p' "$TMP/source-label")"
if [ ! -s "$TMP/pin_log.rs" ]; then
  finish FAIL "The Fold pin-log source is empty."
fi

EVIDENCE="${CLOUD_TRANSACTION_GROUPS_PROOF_EVIDENCE_FILE:-}"
if [ -n "$EVIDENCE" ]; then
  refuse_primary "$EVIDENCE"
  [ -f "$EVIDENCE" ] || finish FAIL "The evidence file is absent."
fi

set +e
BODY="$(python3 "$CHECK" "$TMP/pin_log.rs" "$EVIDENCE" "$MODE" 2>"$TMP/check.err")"
RC=$?
set -e
if [ -s "$TMP/check.err" ]; then
  BODY="${BODY}

Checker error:
$(cat "$TMP/check.err")"
fi
BODY="${BODY}

Source label: ${SOURCE_LABEL}"

if [ "$RC" -ne 0 ]; then
  finish FAIL "$BODY"
fi

if [ "$MODE" = live ]; then
  finish PASS "$BODY"
fi
finish PASS-OFFLINE "$BODY"
