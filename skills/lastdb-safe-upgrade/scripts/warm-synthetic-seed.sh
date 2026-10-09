#!/usr/bin/env bash
# Build the synthetic probe seed for the INSTALLED baseline, ahead of the next
# safe upgrade.
#
# WHY: every upgrade changes the baseline, and the seed must be written by the
# baseline. A cold build took 19 minutes on 2026-10-09 (120 cards), so the first
# PROBE node of each upgrade would pay it. safe-upgrade-lastdb.sh starts this
# script DETACHED after a GREEN live cutover, so the seed for the new baseline is
# built while nobody waits for it. A seed that is already warm costs nothing.
#
# It takes the same host-wide owner lock as an upgrade, so it never runs beside
# a probe or a cutover. It touches only the seed cache. A failure here changes
# nothing live: the next upgrade builds the seed cold.
#
# Usage:
#   warm-synthetic-seed.sh [--detach] [--baseline-bin PATH] [--plist FILE]
#                          [--cards N] [--records N] [--wait-secs N]
#
# --detach starts a new session, prints one line (pid and log path), and returns
# at once. The --baseline-bin and --plist values must be the ones the driver
# uses, or the seed key differs and the warm seed is never found.
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=live-lastdb-env.sh
. "$SCRIPT_DIR/live-lastdb-env.sh"
# shellcheck source=probe-copy-guards.sh
. "$SCRIPT_DIR/probe-copy-guards.sh"
# shellcheck source=owner-lock.sh
. "$SCRIPT_DIR/owner-lock.sh"
# shellcheck source=synthetic-home-checks.sh
. "$SCRIPT_DIR/synthetic-home-checks.sh"

PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
SIDEBIN_DIR="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}"
BASELINE_BIN="$SIDEBIN_DIR/lastdbd"
PLIST="${LASTDB_LAUNCHD_PLIST:-}"
CARDS="${LASTDB_SYNTHETIC_CARDS:-$SYNTH_DEFAULT_CARDS}"
RECORDS="${LASTDB_SYNTHETIC_RECORDS:-$SYNTH_DEFAULT_RECORDS}"
WAIT_SECS="${LASTDB_SYNTHETIC_WARM_WAIT_SECS:-1800}"
DETACH=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/lastdb-safe-upgrade/seed-warm"
KEEP_LOGS=5

usage() {
  sed -n '2,25p' "$0"
  exit 2
}

ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --detach) DETACH=1; shift ;;
    --baseline-bin) BASELINE_BIN="${2:-}"; ARGS+=("$1" "${2:-}"); shift 2 ;;
    --plist) PLIST="${2:-}"; ARGS+=("$1" "${2:-}"); shift 2 ;;
    --cards) CARDS="${2:-}"; ARGS+=("$1" "${2:-}"); shift 2 ;;
    --records) RECORDS="${2:-}"; ARGS+=("$1" "${2:-}"); shift 2 ;;
    --wait-secs) WAIT_SECS="${2:-}"; ARGS+=("$1" "${2:-}"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[seed-warm] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }

synth_count_valid "$CARDS" && synth_count_valid "$RECORDS" \
  || { echo "--cards and --records must be positive integers" >&2; exit 2; }
case "$WAIT_SECS" in ''|*[!0-9]*) echo "--wait-secs must be a non-negative integer" >&2; exit 2 ;; esac
[ -x "$BASELINE_BIN" ] || { echo "baseline daemon is not executable: $BASELINE_BIN" >&2; exit 2; }
[ -f "$PRIMARY_HOME/identity.key" ] && [ ! -L "$PRIMARY_HOME/identity.key" ] \
  || { echo "primary identity.key is absent or a symlink" >&2; exit 2; }

if [ "$DETACH" -eq 1 ]; then
  umask 077
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  log_file="$STATE_DIR/warm-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  # A new session, so the parent's process group (the Loom driver group) does
  # not take this with it when the parent ends. Keep the newest logs only.
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$SELF" ${ARGS[@]+"${ARGS[@]}"} \
    >"$log_file" 2>&1 </dev/null &
  child=$!
  n=0
  for old in $(ls -1t "$STATE_DIR"/warm-*.log 2>/dev/null); do
    n=$((n + 1))
    [ "$n" -le "$KEEP_LOGS" ] || rm -f -- "$old"
  done
  printf 'started pid=%s log=%s\n' "$child" "$log_file"
  exit 0
fi

SEED_ROOT="$(synth_seed_root_default)"
KEY_RC=0
SEED_KEY="$(synth_seed_key_for "$BASELINE_BIN" "$PRIMARY_HOME" "$PLIST" "$CARDS" "$RECORDS")" || KEY_RC=$?
[ "$KEY_RC" -eq 0 ] || { log "cannot compute the seed key (rc=$KEY_RC); nothing built"; exit 1; }
log "baseline $("$BASELINE_BIN" --version 2>/dev/null | awk '{print $NF}') seed key $SEED_KEY root $SEED_ROOT"

if synth_seed_is_complete "$SEED_ROOT/$SEED_KEY" "$SEED_KEY"; then
  log "already warm: $SEED_ROOT/$SEED_KEY"
  exit 0
fi

# The upgrade driver that started this still holds the owner lock. Wait for it.
LOCK_DIR="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR:-/tmp/lastdb-safe-upgrade-owner-$(id -u).lock.d}"
LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
LOCK_HELD=0
release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    safe_upgrade_owner_lock_release "$LOCK_DIR" "$LOCK_TOKEN" 1 || log "owner lock release failed: $LOCK_DIR"
    LOCK_HELD=0
  fi
}
trap release_lock EXIT
if ! LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S="$WAIT_SECS" safe_upgrade_owner_lock_acquire_wait \
    "$LOCK_DIR" "$LOCK_TOKEN" "$$" "seed-warm" "seed-warm"; then
  log "owner lock still busy after ${WAIT_SECS}s; nothing built (the next upgrade builds the seed cold)"
  exit 0
fi
LOCK_HELD=1
log "owner lock acquired"

# Another run may have built it while this one waited for the lock.
if synth_seed_is_complete "$SEED_ROOT/$SEED_KEY" "$SEED_KEY"; then
  log "already warm after the lock wait: $SEED_ROOT/$SEED_KEY"
  exit 0
fi

started="$(date +%s)"
built=""
if built="$(synth_seed_ensure "$SEED_ROOT" "$SEED_KEY" bash "$SCRIPT_DIR/build-synthetic-home.sh" \
    --baseline-bin "$BASELINE_BIN" --identity-from "$PRIMARY_HOME" \
    --cards "$CARDS" --records "$RECORDS" --live-env-plist "$PLIST")"; then
  synth_seed_reclaim_others "$SEED_ROOT" "$SEED_KEY" >/dev/null || true
  log "warm after $(( $(date +%s) - started ))s: $built"
else
  log "seed build failed after $(( $(date +%s) - started ))s; the next upgrade builds it cold"
  exit 1
fi
