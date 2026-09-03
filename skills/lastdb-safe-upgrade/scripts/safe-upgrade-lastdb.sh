#!/usr/bin/env bash
#
# Safe LastDB Mini upgrade against Tom's PRIMARY brain home.
#
# ALWAYS:
#   1. Create one ephemeral CoW rollback point outside $HOME
#   2. Boot the CANDIDATE lastdbd against a throwaway CoW/probe copy
#   3. Require GREEN (identity decrypts, schemas load, real Board values)
#      AND probe RSS stays under the memory-guard ceiling (so live cutover
#      does not immediately thrash-restart under lastdbd-memory-guard)
#      AND the LATENCY BAR: real workloads (Board point read, kanban list
#      scan, brain put write) timed on the candidate's CoW copy must not
#      regress vs the CURRENT live binary on an identical copy —
#      correct-but-slow is RED (incident 2026-07-25/27: 0.23.1 passed the
#      correctness+RSS bars while scans ran 5-20x slower; the live primary
#      was the first place anyone noticed)
#      AND the CANDIDATE CLASS BAR (incident 2026-08-01): refuse Cargo
#      debug paths (target/debug), -dirty version stamps, and binaries
#      ≫ incumbent size (debug/unstripped) before any backup or probe
#      AND the CAS MUTATION BAR (LastGit compound): candidate must enforce
#      `/api/mutation` `expected` preconditions (false → 409 cas_conflict,
#      refused write does not land). Older nodes ignore expected and write
#      unconditionally — silent until LastGit ref/CI CAS collapses. Probe
#      runs on an ephemeral throwaway node of the candidate binary only.
#      AND the DEV PHOTOGRAPH STAMP GATE (Tom 2026-08-19): live cutover is
#      refused unless an ephemeral/CoW copy of real data uploaded a
#      photograph to DEV (not the primary's production backup home) and
#      CAS-flipped backup/latest. Never point the candidate at live ~/.lastdb
#      for that upload. A mock object store is not DEV.
#   4. Only then venue-aware live install:
#        sidebin → atomic install + launchd bootout/bootstrap job-definition reload
#        brew    → brew upgrade + brew services restart (only if formula installed)
#   5. Post-check the LIVE home (incl. lastdb/lastdbd version parity and live
#      RSS vs guard); print rollback if wrong
#
# Design: fold/docs/designs/lastdb-minimal-downtime-cutover.md
#
# NEVER:
#   - Run the candidate against the live ~/.lastdb before probe is GREEN
#   - Skip the rollback point
#   - Install only lastdbd without the sibling lastdb CLI from the same build
#   - Kill/restart the primary on a RED probe
#   - brew upgrade when formula is not installed / primary is sidebin+launchd
#   - Leave rollback copies under $HOME. The current point is released on GREEN;
#     RED retains it temporarily and the next run reclaims it before cloning.
#
# Usage:
#   safe-upgrade-lastdb.sh --probe-only     # rollback point + probe only (no live install)
#   safe-upgrade-lastdb.sh --candidate /path/to/lastdbd --probe-only
#   safe-upgrade-lastdb.sh --version 0.22.8 # fetch that tap release tarball
#   safe-upgrade-lastdb.sh --check-dev-stamp  # refuse/allow live based on DEV photograph receipt only
#
# Live cutovers run only as a Loom lastdb-safe-upgrade graph node. Use
# last-stack-safe-upgrade-loom --candidate /path/to/lastdbd.
# Env (ephemeral rollback):
#   LASTDB_ROLLBACK_ROOT=<path>    # defaults under TMPDIR, never under $HOME
#   LASTDB_ROLLBACK_TTL_HOURS=24   # RED retention contract; next run reclaims
#
set -euo pipefail

# Prefer sidebin primary binary over Homebrew so CURRENT_VER reflects the
# live LaunchAgent daemon, not whatever brew last linked (canary bottles often
# land in /opt/homebrew/bin and false-trigger ALREADY_CURRENT).
export PATH="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:${PATH:-}"

PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
PRIMARY_SOCK="$PRIMARY_HOME/data/folddb.sock"
# routinesd dispatch sets TMPDIR under $HOME/.routines/runs/<run>/scratch; the
# rollback root must stay off HOME (prepare_rollback_root dies on it), so the
# TMPDIR-derived default only applies when it resolves outside the real HOME.
_rollback_default_tmp="${TMPDIR:-/tmp}"
_rollback_home_real="$(cd "$HOME" && pwd -P)"
case "$(cd "$_rollback_default_tmp" 2>/dev/null && pwd -P || printf '%s' "$_rollback_default_tmp")" in
  "$_rollback_home_real"|"$_rollback_home_real"/*) _rollback_default_tmp="/tmp" ;;
esac
ROLLBACK_ROOT="${LASTDB_ROLLBACK_ROOT:-${LASTDB_BACKUP_ROOT:-${_rollback_default_tmp}/lastdb-safe-upgrade-rollback-${UID:-$(id -u)}}}"
ROLLBACK_TTL_HOURS="${LASTDB_ROLLBACK_TTL_HOURS:-24}"
# Resolved under this run's WORK directory after mktemp unless explicitly set.
PROBE_ROOT="${LASTDB_PROBE_ROOT:-}"
SMOKE_SH="${LASTDB_SMOKE_SH:-$HOME/code/edgevector/.claude/run-lastdb-mini-smoke.sh}"
TAP_REPO="EdgeVector/homebrew-lastdb"
# Live install venue (see fold/docs/designs/lastdb-minimal-downtime-cutover.md)
SIDEBIN_DIR="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}"
# Resolve the primary's launchd label from the RUNNING system, never from a
# template default. `com.REPLACE.` is the scrubbed public placeholder (this repo
# ships installable; see last-stack-machine-leak-scan) — it is not a real label,
# and kickstarting it is a SILENT NO-OP that leaves the primary on the old
# binary while every health check still passes.
#
# Incident 2026-08-07: safe-upgrade printed "VERDICT: GREEN ... cutover_s=303"
# having never restarted the daemon, because LASTDB_LAUNCHD_LABEL was unset and
# the placeholder default was kickstarted. Brain:
# papercut-safe-upgrade-reports-green-cutover-without-restarting-primary
resolve_launchd_label() {
  # 1. Explicit override always wins.
  if [ -n "${LASTDB_LAUNCHD_LABEL:-}" ]; then
    printf '%s\n' "$LASTDB_LAUNCHD_LABEL"
    return 0
  fi
  # 2. A loaded job whose label looks like the primary daemon.
  local found
  found="$(launchctl list 2>/dev/null \
    | awk '{print $3}' \
    | grep -E '\.lastdbd-primary(-[0-9]+)?$' \
    | grep -v '^com\.REPLACE\.' \
    | head -1)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  # 3. A LaunchAgent plist whose ProgramArguments points at the sidebin daemon.
  local plist label
  for plist in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$plist" ] || continue
    if /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$plist" 2>/dev/null \
        | grep -qF "$SIDEBIN_DIR/lastdbd"; then
      label="$(basename "$plist" .plist)"
      case "$label" in
        *memory-guard*) continue ;;
      esac
      printf '%s\n' "$label"
      return 0
    fi
  done
  return 1
}

LAUNCHD_LABEL="$(resolve_launchd_label || true)"
LAUNCHD_LABEL_RESOLVED=1
if [ -z "$LAUNCHD_LABEL" ]; then
  LAUNCHD_LABEL="com.REPLACE.lastdbd-primary-506"
  LAUNCHD_LABEL_RESOLVED=0
fi
LAUNCHD_PLIST="${LASTDB_LAUNCHD_PLIST:-$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist}"


PROBE_ONLY=0
ASSUME_YES=0
CHECK_DEV_STAMP=0
CANDIDATE_BIN=""
CANDIDATE_CLI_BIN=""
TARGET_VERSION=""
WORK=""
BACKUP=""
ROLLBACK_READY=0

usage() {
  sed -n '2,34p' "$0"
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe-only) PROBE_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --check-dev-stamp) CHECK_DEV_STAMP=1; shift ;;
    --candidate) CANDIDATE_BIN="$2"; shift 2 ;;
    --version) TARGET_VERSION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[safe-upgrade] %s\n' "$*"; }
die() { printf '[safe-upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[safe-upgrade] WARN: %s\n' "$*" >&2; }

if [ "$PROBE_ONLY" -eq 0 ] && [ "$CHECK_DEV_STAMP" -eq 0 ]; then
  [ "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-0}" = "1" ] \
    || die "live cutover requires the Loom lastdb-safe-upgrade graph; use last-stack-safe-upgrade-loom --candidate PATH"
  [ -n "${LOOM_EXEC_ID:-}" ] \
    || die "live cutover requires a Loom execution id; direct driver bypass is refused"
fi

# An unloaded primary is a total factory outage — brain, board, Situations,
# LastGit CI and every routine go dark at once — so it pages instead of only
# writing a log line nobody reads until morning. Same argv as
# last-stack-real-human-notify / factory-health.
page_human() {
  local msg="$1" ra_bin="${RA_BIN:-ra}"
  command -v "$ra_bin" >/dev/null 2>&1 || {
    warn "cannot page: $ra_bin not on PATH — $msg"
    return 0
  }
  "$ra_bin" notify "$msg" --priority high >/dev/null 2>&1 \
    || warn "page failed via $ra_bin — $msg"
}

# Memory-guard ceiling used by com.REPLACE.lastdbd-memory-guard (Tom, 2026-07-14).
# Env LASTDBD_RSS_LIMIT_MB wins; else LaunchAgent plist(s); else the resident
# primary default. Keep the primary daemon's own plist aligned before kickstart
# so lastdbd does not boot with its lower binary default while the guard allows
# the larger resident ceiling.
# Probe/live must stay under this or the guard SIGTERMs primary in a thrash loop
# (incident after 2026-07-22 sled-free cutover: candidate ~8.5G vs limit 6G).
MEMORY_GUARD_PLIST="${LASTDBD_MEMORY_GUARD_PLIST:-$HOME/Library/LaunchAgents/com.REPLACE.lastdbd-memory-guard.plist}"
DEFAULT_LASTDBD_RSS_LIMIT_MB="${LASTDBD_DEFAULT_RSS_LIMIT_MB:-16384}"
# Extra headroom fraction (0–100). Fail probe if RSS >= limit * (100-HEADROOM)/100.
# Default 10% so live does not sit right on the kill line after settle.
RSS_HEADROOM_PCT="${LASTDB_PROBE_RSS_HEADROOM_PCT:-10}"
# After data-plane ready, wait this long then sample RSS (embeddings finish loading).
RSS_SETTLE_SECS="${LASTDB_PROBE_RSS_SETTLE_SECS:-45}"
RSS_SAMPLE_SECS="${LASTDB_PROBE_RSS_SAMPLE_SECS:-15}"

# Latency bar (incident 2026-07-25/27): the 0.23.1 cutover was GREEN on the
# correctness + RSS bars while scan-shaped reads (kanban list, brain range
# queries) ran 5-20x slower on the new binary — the live primary was the first
# place anyone noticed. The probe therefore times real workloads on the
# candidate's CoW copy AND on an identical copy served by the CURRENT live
# binary, and fails RED on regression. Correct-but-slow is NOT GREEN.
LAT_SKIP="${LASTDB_PROBE_LAT_SKIP:-0}"              # 1 = skip bar (Tom clearance only)
LAT_SAMPLES="${LASTDB_PROBE_LAT_SAMPLES:-3}"        # samples per op; median wins
LAT_RATIO="${LASTDB_PROBE_LAT_RATIO:-3}"            # RED if cand > ratio x baseline
# Floor was 1000ms; exclusive CoW scans often sit under 1s so the ratio bar
# never fired (incident 2026-08-01: debug cand 670ms vs base 503ms both under
# floor). 250ms still filters noise while applying 3× to real product ops.
LAT_FLOOR_MS="${LASTDB_PROBE_LAT_FLOOR_MS:-250}"   # ratio bar only applies above this
LAT_ABS_MAX_MS="${LASTDB_PROBE_LAT_ABS_MAX_MS:-20000}"  # RED when no baseline; WARN when baseline is equally slow
LAT_OP_TIMEOUT_SECS="${LASTDB_PROBE_LAT_OP_TIMEOUT_SECS:-120}"  # per-sample kill + scored as this
LIVE_LAT_ENFORCE="${LASTDB_LIVE_LAT_ENFORCE:-0}"    # 1 = live post-check latency is RED, not WARN
LIVE_CONFIG_ENFORCE="${LASTDB_LIVE_CONFIG_ENFORCE:-0}" # 1 = missing plist env keys are RED
# Correlated / aggregate term (2026-08-05): per-op 3× alone passed a canary that
# was slower on EVERY op at 1.6–2.4×. See latency-bar-checks.sh.
# LASTDB_PROBE_LAT_CORR_SKIP=1 is Tom clearance only.
export LASTDB_PROBE_LAT_CORR_RATIO="${LASTDB_PROBE_LAT_CORR_RATIO:-1.4}"
export LASTDB_PROBE_LAT_GEO_MEAN_MAX="${LASTDB_PROBE_LAT_GEO_MEAN_MAX:-1.5}"
export LASTDB_PROBE_LAT_CORR_MIN_OPS="${LASTDB_PROBE_LAT_CORR_MIN_OPS:-2}"
export LASTDB_PROBE_LAT_CORR_SKIP="${LASTDB_PROBE_LAT_CORR_SKIP:-0}"

# CAS mutation bar (LastGit #217 compound): candidate must honor `expected`
# preconditions on /api/mutation. LASTDB_PROBE_CAS_SKIP=1 is Tom clearance only.
CAS_SKIP="${LASTDB_PROBE_CAS_SKIP:-0}"

# Candidate class gates (incident 2026-08-01: primary cut over to worktree
# target/debug/lastdbd …-dirty). Sourced pure helpers.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=candidate-class-checks.sh
. "$_SCRIPT_DIR/candidate-class-checks.sh"
# shellcheck source=binary-pair-checks.sh
. "$_SCRIPT_DIR/binary-pair-checks.sh"
# shellcheck source=latency-bar-checks.sh
. "$_SCRIPT_DIR/latency-bar-checks.sh"
# shellcheck source=live-lastdb-env.sh
. "$_SCRIPT_DIR/live-lastdb-env.sh"
# shellcheck source=dev-photograph-stamp-gate.sh
. "$_SCRIPT_DIR/dev-photograph-stamp-gate.sh"
# shellcheck source=launchd-job-checks.sh
. "$_SCRIPT_DIR/launchd-job-checks.sh"
# shellcheck source=live-socket-health.sh
. "$_SCRIPT_DIR/live-socket-health.sh"
# shellcheck source=owner-lock.sh
. "$_SCRIPT_DIR/owner-lock.sh"
# shellcheck source=deadline.sh
. "$_SCRIPT_DIR/deadline.sh"
CAS_PROBE_SH="$_SCRIPT_DIR/cas-mutation-probe.sh"

if [ "${CHECK_DEV_STAMP:-0}" -eq 1 ]; then
  DEV_STAMP_OUT=""
  set +e
  DEV_STAMP_OUT="$(assert_dev_photograph_stamp_ok "$(dev_stamp_receipt_path)" "$PRIMARY_HOME" 2>&1)"
  DEV_STAMP_RC=$?
  set -e
  if [ -n "$DEV_STAMP_OUT" ]; then
    printf '%s\n' "$DEV_STAMP_OUT"
  fi
  if [ "$DEV_STAMP_RC" -ne 0 ]; then
    echo "VERDICT: RED"
    echo "REASON: live cutover refused — DEV photograph stamp is missing or RED (ephemeral/CoW + DEV upload + CAS latest required; never live ~/.lastdb; never production backup home)"
    exit 1
  fi
  echo "VERDICT: GREEN"
  echo "SUMMARY: DEV photograph stamp receipt is GREEN; live cutover is allowed to proceed (this flag does not install)"
  exit 0
fi

release_rollback_point() {
  [ "${ROLLBACK_READY:-0}" -eq 1 ] || return 0
  [ -n "${BACKUP:-}" ] && [ -d "$BACKUP" ] && rm -rf "$BACKUP"
  ROLLBACK_READY=0
  rmdir "$ROLLBACK_ROOT" 2>/dev/null || true
  log "rollback: released after GREEN ($BACKUP)"
}

retain_rollback_point() {
  [ "${ROLLBACK_READY:-0}" -eq 1 ] || return 0
  mkdir -p "$BACKUP/.safe-upgrade"
  {
    printf 'retained_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'ttl_hours=%s\n' "$ROLLBACK_TTL_HOURS"
    printf 'cleanup_owner=next-lastdb-safe-upgrade-run\n'
  } >"$BACKUP/.safe-upgrade/retention"
  warn "rollback: RED retained at $BACKUP ttl_hours=$ROLLBACK_TTL_HOURS cleanup_owner=next-lastdb-safe-upgrade-run"
}

OWNER_LOCK_DIR="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR:-/tmp/lastdb-safe-upgrade-owner-${UID:-$(id -u)}.lock.d}"
OWNER_LOCK_TOKEN="$$.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
OWNER_LOCK_HELD=0
RESTART_INTENT_PATH=""
RESTART_INTENT_START_REQUESTED=0
DRIVER_ENDED_STEP=0

cleanup_work() {
  local rc=$?
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  [ -n "${CUTOVER_LOCK:-}" ] && rm -f "$CUTOVER_LOCK"
  if type cleanup_upgrade_restart_intent >/dev/null 2>&1; then
    cleanup_upgrade_restart_intent
  fi
  # GREEN / probe-only / operator abort call release_rollback_point first
  # (ROLLBACK_READY=0). Any other end — including a loom drive deadline that
  # reparents this script and then SIGTERM/SIGHUP with a false-zero EXIT —
  # keeps the newest rollback point so a later attempt can reuse it.
  if [ "${ROLLBACK_READY:-0}" -eq 1 ]; then
    retain_rollback_point
    if [ "${DRIVER_ENDED_STEP:-0}" -eq 1 ]; then
      warn "rollback: driver ended the step; kept newest point ${BACKUP:-none}"
    fi
  fi
  if type safe_upgrade_owner_lock_release >/dev/null 2>&1; then
    safe_upgrade_owner_lock_release "$OWNER_LOCK_DIR" "$OWNER_LOCK_TOKEN" "$OWNER_LOCK_HELD" \
      || warn "owner lock release failed: $OWNER_LOCK_DIR"
  fi
  return "$rc"
}
on_driver_end() {
  DRIVER_ENDED_STEP=1
  exit 143
}
trap 'on_driver_end' HUP INT TERM
trap cleanup_work EXIT

backup_essentials_ok() {
  local root="$1"
  # identity + data dir required. Storage is either legacy sled (data/db) or
  # Last Store collections under data/data/ (Mini LASTDB_ENGINE=laststore).
  [ -f "$root/identity.key" ] && [ -d "$root/data" ] || return 1
  [ -e "$root/data/db" ] || [ -d "$root/data/data" ] || [ -d "$root/data/laststore" ]
}

backup_data_is_not_live() {
  local root="$1" backup_data live_data
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  backup_data="$(cd "$root/data" 2>/dev/null && pwd -P || true)"
  live_data="$(cd "$PRIMARY_HOME/data" 2>/dev/null && pwd -P || true)"
  [ -n "$backup_data" ] && [ "$backup_data" != "$live_data" ]
}

# Routine safe-upgrade rollback name: pre-<cand>-from-<cur>-YYYYMMDDTHHMMSSZ.
# The narrow classifier keeps cleanup confined to this script's own artifacts.
# Portable (macOS Bash 3.2): no ${var: -N} substrings.
is_routine_pre_upgrade_backup() {
  local base="$1" ts
  case "$base" in
    pre-*-from-*) ;;
    *) return 1 ;;
  esac
  ts="$(printf '%s\n' "$base" | sed -n 's/.*-\([0-9]\{8\}T[0-9]\{6\}Z\)$/\1/p')"
  [ -n "$ts" ] || return 1
  return 0
}

newest_routine_rollback_point() {
  local d base ts newest="" newest_ts=""
  [ -d "$ROLLBACK_ROOT" ] || return 0
  for d in "$ROLLBACK_ROOT"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    base="$(basename "$d")"
    is_routine_pre_upgrade_backup "$base" || continue
    ts="$(printf '%s\n' "$base" | sed -n 's/.*-\([0-9]\{8\}T[0-9]\{6\}Z\)$/\1/p')"
    [ -n "$ts" ] || continue
    if [ -z "$newest_ts" ] || [ "$ts" \> "$newest_ts" ]; then
      newest="$d"
      newest_ts="$ts"
    fi
  done
  [ -n "$newest" ] && printf '%s\n' "$newest"
  return 0
}

prepare_rollback_root() {
  local root_real home_real d base reclaimed=0 newest=""
  mkdir -p "$ROLLBACK_ROOT"
  [ ! -L "$ROLLBACK_ROOT" ] || die "rollback root must not be a symlink: $ROLLBACK_ROOT"
  root_real="$(cd "$ROLLBACK_ROOT" && pwd -P)"
  home_real="$(cd "$HOME" && pwd -P)"
  case "$root_real" in
    "$home_real"|"$home_real"/*)
      die "rollback root must be ephemeral and outside HOME: $root_real"
      ;;
  esac
  newest="$(newest_routine_rollback_point)"
  for d in "$ROLLBACK_ROOT"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    base="$(basename "$d")"
    is_routine_pre_upgrade_backup "$base" || continue
    if [ -n "$newest" ] && [ "$d" = "$newest" ]; then
      continue
    fi
    log "rollback: reclaim previous retained point $d"
    rm -rf "$d"
    reclaimed=$((reclaimed + 1))
  done
  log "rollback: root=$root_real previous_reclaimed=$reclaimed kept_newest=${newest:-none} ttl_hours=$ROLLBACK_TTL_HOURS cleanup_owner=next-lastdb-safe-upgrade-run"
}

rss_mb_of_pid() {
  local pid="$1" rss_kb
  rss_kb="$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo 0)"
  [ -n "$rss_kb" ] || rss_kb=0
  echo $((rss_kb / 1024))
}

resolve_rss_limit_mb() {
  if [ -n "${LASTDBD_RSS_LIMIT_MB:-}" ]; then
    echo "$LASTDBD_RSS_LIMIT_MB"
    return
  fi
  if [ -n "${LASTDB_PROBE_RSS_LIMIT_MB:-}" ]; then
    echo "$LASTDB_PROBE_RSS_LIMIT_MB"
    return
  fi
  local from_plist
  if [ -f "$MEMORY_GUARD_PLIST" ]; then
    from_plist="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB' "$MEMORY_GUARD_PLIST" 2>/dev/null || true)"
    if [ -n "$from_plist" ] && [ "$from_plist" -gt 0 ] 2>/dev/null; then
      echo "$from_plist"
      return
    fi
  fi
  if [ -f "$LAUNCHD_PLIST" ]; then
    from_plist="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB' "$LAUNCHD_PLIST" 2>/dev/null || true)"
    if [ -n "$from_plist" ] && [ "$from_plist" -gt 0 ] 2>/dev/null; then
      echo "$from_plist"
      return
    fi
  fi
  echo "$DEFAULT_LASTDBD_RSS_LIMIT_MB"
}

resolve_live_rss_limit_mb() {
  # Probe-only overrides must not be written back into the live LaunchAgent.
  local from_plist
  if [ -n "${LASTDBD_RSS_LIMIT_MB:-}" ]; then
    echo "$LASTDBD_RSS_LIMIT_MB"
    return
  fi
  if [ -f "$MEMORY_GUARD_PLIST" ]; then
    from_plist="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB' "$MEMORY_GUARD_PLIST" 2>/dev/null || true)"
    if [ -n "$from_plist" ] && [ "$from_plist" -gt 0 ] 2>/dev/null; then
      echo "$from_plist"
      return
    fi
  fi
  if [ -f "$LAUNCHD_PLIST" ]; then
    from_plist="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB' "$LAUNCHD_PLIST" 2>/dev/null || true)"
    if [ -n "$from_plist" ] && [ "$from_plist" -gt 0 ] 2>/dev/null; then
      echo "$from_plist"
      return
    fi
  fi
  echo "$DEFAULT_LASTDBD_RSS_LIMIT_MB"
}

rss_fail_threshold_mb() {
  local limit="$1" headroom="$RSS_HEADROOM_PCT"
  if ! [ "$headroom" -ge 0 ] 2>/dev/null; then headroom=10; fi
  if [ "$headroom" -gt 50 ]; then headroom=50; fi
  echo $((limit * (100 - headroom) / 100))
}

# --- latency measurement helpers ---------------------------------------------

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

median_of() {
  # median of the integer args
  printf '%s\n' "$@" | sort -n \
    | awk '{a[NR]=$1} END {if (NR==0) {print -1} else if (NR%2) {print a[(NR+1)/2]} else {print int((a[NR/2]+a[NR/2+1])/2)}}'
}

# Latency ops. Each takes one arg and must exit non-zero on failure. These are
# the REAL workloads: the keyed point read from the smoke bar, the scan-shaped
# read that regressed in 0.23.1 (kanban list), and a real brain upsert (writes
# only ever land on the throwaway CoW copy, never the primary).
op_lat_point() {
  # $1 = socket path
  curl -sS --max-time "$LAT_OP_TIMEOUT_SECS" --unix-socket "$1" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
    -H 'Content-Type: application/json' \
    --data '{"schema_name":"Board","fields":["title"],"filter":{"HashKey":"default"}}' \
    http://x/api/query 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
}

op_lat_scan() {
  # $1 = probe copy home
  env FOLDDB_SOCKET_PATH="$1/data/folddb.sock" LASTDB_HOME="$1" FOLDDB_HOME="$1" \
    kanban list --column todo --json >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Row-count bar: a read that answers fast with ZERO rows is NOT green.
#
# 2026-09-03: lastdbd 0.23.3-1535 shipped #1893 "Keep HashKey on a named
# HashRange schema on that schema's key layout". Every kanban BoardCards
# HashKey/HashRangePrefix read then returned ok:true with returned_count=0 on
# the primary — the whole board read empty, pickup gates saw zero cards, and
# ship rate went to 0. The probe passed GREEN because op_lat_point only
# asserted `.ok == true` and op_lat_scan discarded stdout entirely: a query
# that answers "no rows" in 169 ms is the FASTEST possible answer, so every
# latency bar rewarded the regression.
#
# These two ops return the row COUNT the same query yields, so the bar can
# compare candidate against baseline on identical CoW data. Baseline > 0 with
# candidate == 0 is a read-path regression and is RED.
# Brain: papercut-lastdb-1535-hashrange-board-queries-return-zero-rows-after-cutover-20260903.
op_rows_point() {
  # $1 = socket path; prints the row count, or -1 when unmeasurable
  local body count
  body="$(curl -sS --max-time "$LAT_OP_TIMEOUT_SECS" --unix-socket "$1" -H 'Host: localhost' \
    -H 'X-LastDB-Client: lastdb-safe-upgrade' -H 'Content-Type: application/json' \
    --data '{"schema_name":"Board","fields":["title"],"filter":{"HashKey":"default"}}' \
    http://x/api/query 2>/dev/null)" || { echo "-1"; return 0; }
  count="$(printf '%s' "$body" | jq -r 'if .ok != true then -1
    elif (.returned_count // empty) != null then .returned_count
    elif (.results // empty) != null then (.results | length)
    elif (.rows // empty) != null then (.rows | length)
    else -1 end' 2>/dev/null)"
  case "$count" in ''|*[!0-9-]*) count="-1" ;; esac
  echo "$count"
}

op_rows_scan() {
  # $1 = probe copy home; prints the card count, or -1 when unmeasurable
  local body count
  body="$(env FOLDDB_SOCKET_PATH="$1/data/folddb.sock" LASTDB_HOME="$1" FOLDDB_HOME="$1" \
    kanban list --column todo --json 2>/dev/null)" || { echo "-1"; return 0; }
  count="$(printf '%s' "$body" | jq -r '(.total // (.cards | length) // -1)' 2>/dev/null)"
  case "$count" in ''|*[!0-9-]*) count="-1" ;; esac
  echo "$count"
}

# Compare one candidate/baseline row-count pair.
# $1 = label, $2 = candidate count, $3 = baseline count.
# Prints one verdict line; returns 1 only on a real zero-row regression.
rowcount_verdict() {
  local label="$1" cand="$2" base="$3"
  if ! [ "$cand" -ge 0 ] 2>/dev/null; then
    echo "rowcount $label SKIPPED: candidate count unmeasurable (got '${cand}')"
    return 0
  fi
  if ! [ "$base" -ge 0 ] 2>/dev/null; then
    echo "rowcount $label SKIPPED: no baseline count (got '${base}') — cannot tell an empty board from an empty answer"
    return 0
  fi
  if [ "$base" -gt 0 ] && [ "$cand" -eq 0 ]; then
    echo "rowcount $label RED: baseline returned ${base} rows, candidate returned 0 on the SAME CoW data — read-path regression, not an empty board"
    return 1
  fi
  if [ "$base" -gt 0 ] && [ "$cand" -lt "$base" ]; then
    echo "rowcount $label WARN: candidate ${cand} rows vs baseline ${base} on the same CoW data (copies are taken moments apart; investigate if the gap is large)"
    return 0
  fi
  echo "rowcount $label ok: candidate=${cand} baseline=${base}"
  return 0
}

op_lat_write() {
  # $1 = probe copy home
  printf -- '---\ntype: reference\nslug: safe-upgrade-latency-probe-scratch\ntitle: safe-upgrade latency probe scratch\n---\nUpsert from the safe-upgrade latency bar. Only ever written to throwaway CoW probe copies.\n' \
    | env FBRAIN_FOLDDB_SOCKET="$1/data/folddb.sock" LASTDB_HOME="$1" FOLDDB_HOME="$1" \
      brain put >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Durability canary: an acked write must survive the cutover restart.
#
# 2026-08-18: two loom execution terminal-status writes were acknowledged and
# READ BACK on the live primary (23:08–23:12Z), then vanished — the rows
# regressed to their previous version. The defer cap was 0, and the next
# safe-upgrade cutover recorded "did not complete its clean drain". Every bar
# in this script would have passed GREEN over that loss: health, version,
# schemas, Board title, RSS, and latency are liveness/read checks, and the
# latency write probe only touches throwaway CoW copies. Nothing asserted that
# a write acked by the OLD daemon is still there when the NEW daemon serves.
# Brain: papercut-lastdb-acked-write-lost-loom-terminal-status-regressed.
#
# Mechanism: immediately before any live change, upsert N fixed-slug sentinels
# through `brain put --durable --json`, require the node's exact `durable`
# receipt, and read each nonce back. After the cutover, read them again on the
# new daemon. A queued write plus resident read-back is not durability proof:
# that exact sequence lost sentinel 4 during the 2026-09-02 cutover. A stale
# nonce after restart is the observed loss shape (the last write to one key
# dropped and the prior version survived). Fixed slugs keep the store flat; N
# spreads sentinels across hash groups because the loss was per-key, not
# per-interval. There is deliberately no skip flag — a durability bar that can
# be skipped recurs silently.
# ---------------------------------------------------------------------------
DURABILITY_N="${LASTDB_DURABILITY_CANARY_N:-4}"
DURABILITY_READ_WAIT_S="${LASTDB_DURABILITY_READ_WAIT_S:-120}"
DURABILITY_SLUG_PREFIX="lastdb-safe-upgrade-durability-canary"
DURABILITY_NONCE=""
DURABILITY_MODE="durable"

cleanup_upgrade_restart_intent() {
  [ "${RESTART_INTENT_START_REQUESTED:-0}" -eq 0 ] || return 0
  [ -n "${RESTART_INTENT_PATH:-}" ] || return 0
  [ -e "$RESTART_INTENT_PATH" ] || return 0
  rm -f "$RESTART_INTENT_PATH"
  log "restart intent: removed after the cutover stopped before a successful start request"
}

write_upgrade_restart_intent() {
  local current_session="$PRIMARY_HOME/current-session.json"
  if [ ! -s "$current_session" ]; then
    log "restart intent: no current session record; the daemon will use its clean-exit and build-change fallback"
    return 0
  fi

  local previous_pid intent_tmp
  previous_pid="$(jq -er 'if (.pid | type) == "number" and .pid > 0 then .pid else error("invalid pid") end' "$current_session" 2>/dev/null)" \
    || die "restart intent: current session has no valid pid ($current_session)"
  RESTART_INTENT_PATH="$PRIMARY_HOME/restart-intent.json"
  intent_tmp="${RESTART_INTENT_PATH}.tmp.$$"
  if ! (
    umask 077
    printf '{"cause":"upgrade","previous_pid":%s,"created_at":%s}\n' \
      "$previous_pid" "$(date +%s)" >"$intent_tmp"
    mv -f "$intent_tmp" "$RESTART_INTENT_PATH"
  ); then
    rm -f "$intent_tmp"
    die "restart intent: could not atomically write $RESTART_INTENT_PATH"
  fi
  log "restart intent: armed cause=upgrade previous_pid=$previous_pid path=$RESTART_INTENT_PATH"
}

durability_slug() { printf '%s-%d' "$DURABILITY_SLUG_PREFIX" "$1"; }

durability_read_body() {
  # $1 = slug. stdout: the record as brain prints it (empty on any failure).
  run_op_with_deadline 15 env FBRAIN_FOLDDB_SOCKET="$PRIMARY_SOCK" \
    LASTDB_HOME="$PRIMARY_HOME" FOLDDB_HOME="$PRIMARY_HOME" \
    brain get "$1" 2>/dev/null || true
}

durability_output_is_http_400() {
  # Distinguish "old daemon has no durable-receipt API" from other write
  # failures. HTTP 400 is the deny_unknown_fields rejection of `durability`.
  printf '%s' "$1" | grep -Eqi \
    'HTTP[[:space:]]*400|status[[:space:]]*[:=][[:space:]]*"?400"?([^0-9]|$)|400[[:space:]]+Bad[[:space:]]+Request'
}

durability_write_sentinels() {
  # Runs BEFORE any live change; a failure here aborts a not-yet-started
  # cutover, which is the honest outcome — an upgrade whose durability bar
  # cannot arm must not proceed to the restart that bar exists to judge.
  #
  # Two arming modes:
  #   durable         — --durable returned .durability=="durable" (preferred)
  #   queued+readback — --durable returned HTTP 400 (pre-receipt API daemon),
  #                     a queued put of the same sentinel succeeded, and
  #                     read-back on the old daemon returned this run's nonce.
  #                     Post-cutover nonce read-back remains mandatory.
  # Any non-400 durable-put failure still hard-aborts.
  DURABILITY_NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  DURABILITY_MODE="durable"
  local i slug body receipt put_rc put_err used_fallback=0
  local errf="${TMPDIR:-/tmp}/lastdb-su-durability-err.$$"
  for i in $(seq 1 "$DURABILITY_N"); do
    slug="$(durability_slug "$i")"
    body="$(
      printf -- '---\ntype: reference\nslug: %s\ntitle: safe-upgrade durability canary %d (constant slug; nonce changes per run)\n---\nnonce: %s#%d\n\nWritten by lastdb-safe-upgrade immediately before the cutover restart and\nread back after it. A stale nonce after an upgrade means the primary lost an\nacknowledged write across the restart. Safe to keep; carries no other\nmeaning. Rationale: brain\npapercut-lastdb-acked-write-lost-loom-terminal-status-regressed.\n' \
        "$slug" "$i" "$DURABILITY_NONCE" "$i"
    )"
    put_rc=0
    receipt="$(
      printf '%s' "$body" \
        | env FBRAIN_FOLDDB_SOCKET="$PRIMARY_SOCK" LASTDB_HOME="$PRIMARY_HOME" FOLDDB_HOME="$PRIMARY_HOME" \
          brain put --durable --json 2>"$errf"
    )" || put_rc=$?
    put_err="$(cat "$errf" 2>/dev/null || true)"
    if [ "$put_rc" -eq 0 ] && printf '%s' "$receipt" | jq -e \
      '.ok == true and .durability == "durable"' >/dev/null 2>&1; then
      durability_read_body "$slug" | grep -qF "nonce: ${DURABILITY_NONCE}#${i}" \
        || { rm -f "$errf"; die "durability canary: pre-cutover read-back of $slug did not return this run's nonce — primary already unhealthy; aborting before any live change"; }
      continue
    fi
    if durability_output_is_http_400 "${receipt}
${put_err}"; then
      log "durability canary: $slug --durable put HTTP 400 on old daemon ${CURRENT_VER:-unknown} (no durable-receipt API); printing response body"
      if [ -n "$put_err" ]; then
        log "durability canary: HTTP 400 stderr: $(printf '%s' "$put_err" | tr '\n' ' ')"
      fi
      if [ -n "$receipt" ]; then
        log "durability canary: HTTP 400 stdout: $(printf '%s' "$receipt" | tr '\n' ' ')"
      fi
      put_rc=0
      receipt="$(
        printf '%s' "$body" \
          | env FBRAIN_FOLDDB_SOCKET="$PRIMARY_SOCK" LASTDB_HOME="$PRIMARY_HOME" FOLDDB_HOME="$PRIMARY_HOME" \
            brain put --json 2>"$errf"
      )" || put_rc=$?
      put_err="$(cat "$errf" 2>/dev/null || true)"
      if [ "$put_rc" -ne 0 ] || ! printf '%s' "$receipt" | jq -e '.ok == true' >/dev/null 2>&1; then
        rm -f "$errf"
        die "durability canary: HTTP 400 durable put, then queued put of $slug failed — aborting before any live change (${put_err})"
      fi
      durability_read_body "$slug" | grep -qF "nonce: ${DURABILITY_NONCE}#${i}" \
        || { rm -f "$errf"; die "durability canary: queued+readback of $slug did not return this run's nonce — aborting before any live change"; }
      used_fallback=1
      continue
    fi
    rm -f "$errf"
    die "durability canary: pre-cutover durable write of $slug failed — aborting before any live change (the canary must arm to prove the cutover keeps durable writes; not HTTP 400, so the daemon appears to support durable receipts)"
  done
  rm -f "$errf"
  if [ "$used_fallback" -eq 1 ]; then
    DURABILITY_MODE="queued+readback"
    log "durability canary: armed mode=queued+readback old_build=${CURRENT_VER:-unknown} — $DURABILITY_N sentinels queued, acknowledged, and read back on the old daemon (nonce $DURABILITY_NONCE). Post-cutover nonce read-back remains mandatory."
  else
    DURABILITY_MODE="durable"
    log "durability canary: armed mode=durable — $DURABILITY_N sentinels durably persisted and read back on the old daemon (nonce $DURABILITY_NONCE)"
  fi
}

durability_verify_after_cutover() {
  # Same read-vs-mismatch split as the version assertion above: a read that
  # has not answered yet says nothing (node may still be warming — retry until
  # the deadline), while a read that SUCCEEDS with a stale nonce is a proven
  # acked-write loss and cannot improve by waiting.
  local deadline=$(( $(date +%s) + DURABILITY_READ_WAIT_S ))
  local i slug body lost="" unreadable=""
  for i in $(seq 1 "$DURABILITY_N"); do
    slug="$(durability_slug "$i")"
    while :; do
      body="$(durability_read_body "$slug")"
      if [ -n "$body" ]; then
        printf '%s' "$body" | grep -qF "nonce: ${DURABILITY_NONCE}#${i}" \
          || lost="$lost $slug"
        break
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        unreadable="$unreadable $slug"
        break
      fi
      sleep 2
    done
  done
  if [ -n "$lost" ] || [ -n "$unreadable" ]; then
    echo ""
    echo "VERDICT: RED"
    [ -n "$lost" ] && \
      echo "REASON: acked-write durability regression — sentinel(s)$lost read back with a STALE nonce after cutover: the old daemon acknowledged these writes and the new daemon does not have them (loss class: papercut-lastdb-acked-write-lost-loom-terminal-status-regressed)"
    [ -n "$unreadable" ] && \
      echo "REASON: durability sentinel(s)$unreadable unreadable ${DURABILITY_READ_WAIT_S}s after cutover — durability of the cutover is UNPROVEN"
    echo "BACKUP: $BACKUP"
    echo "BINARY ROLLBACK (preferred first try, sidebin):"
    echo "  cp -a $SIDEBIN_DIR/lastdbd.bak-pre-* $SIDEBIN_DIR/lastdbd  # pick newest bak"
    echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
    echo "NOTE: rolling back the binary does NOT recover the lost writes; it stops the bleeding. Audit recent writes on other apps before trusting the store."
    die "durability canary failed after cutover — acked writes did not survive the restart"
  fi
  log "durability canary: $DURABILITY_N/$DURABILITY_N sentinels survived the cutover (nonce $DURABILITY_NONCE)"
}

measure_op_median_ms() {
  # $1 = op fn, $2 = op arg, $3 = label. stdout: median ms, or -1 unmeasurable.
  # A sample the deadline kills scores as the full deadline (slow IS the signal).
  local fn="$1" arg="$2" label="$3"
  local vals="" t0 t1 rc n=0 i
  for i in $(seq 1 "$LAT_SAMPLES"); do
    t0="$(now_ms)"
    rc=0
    run_op_with_deadline "$LAT_OP_TIMEOUT_SECS" "$fn" "$arg" || rc=$?
    t1="$(now_ms)"
    if [ "$rc" -eq 124 ]; then
      warn "latency $label: sample $i hit the ${LAT_OP_TIMEOUT_SECS}s deadline"
      vals="$vals $((LAT_OP_TIMEOUT_SECS * 1000))"
      n=$((n + 1))
    elif [ "$rc" -ne 0 ]; then
      warn "latency $label: sample $i failed (rc=$rc)"
    else
      vals="$vals $((t1 - t0))"
      n=$((n + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then
    echo "-1"
    return 0
  fi
  # shellcheck disable=SC2086
  median_of $vals
}

measure_op_once_ms() {
  # $1 = op fn, $2 = op arg, $3 = label. stdout: one sample ms, or -1.
  local fn="$1" arg="$2" label="$3"
  local t0 t1 rc=0
  t0="$(now_ms)"
  run_op_with_deadline "$LAT_OP_TIMEOUT_SECS" "$fn" "$arg" || rc=$?
  t1="$(now_ms)"
  if [ "$rc" -eq 124 ]; then
    warn "latency $label: sample hit the ${LAT_OP_TIMEOUT_SECS}s deadline"
    echo $((LAT_OP_TIMEOUT_SECS * 1000))
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    warn "latency $label: sample failed (rc=$rc)"
    echo "-1"
    return 0
  fi
  echo $((t1 - t0))
}

discard_op_warmup() {
  local fn="$1" arg="$2" label="$3"
  run_op_with_deadline "$LAT_OP_TIMEOUT_SECS" "$fn" "$arg" >/dev/null 2>&1 || true
  log "latency $label: discarded warmup sample"
}

metric_val() {
  # $1 = metrics file, $2 = key
  awk -F= -v k="$2" '$1==k{print $2}' "$1" 2>/dev/null | head -1
}

# live_lastdb_env_pairs is defined in live-lastdb-env.sh (shared with the
# write-path CoW probe). Never invent a second env-mirror.

resolve_baseline_bin() {
  # The binary the live primary actually runs — launchd plist first, then
  # sidebin, then PATH. LASTDB_PROBE_BASELINE_BIN overrides.
  if [ -n "${LASTDB_PROBE_BASELINE_BIN:-}" ]; then
    [ -x "$LASTDB_PROBE_BASELINE_BIN" ] && echo "$LASTDB_PROBE_BASELINE_BIN"
    return 0
  fi
  local prog
  prog="$(plutil -extract ProgramArguments.0 raw "$LAUNCHD_PLIST" 2>/dev/null || true)"
  if [ -n "$prog" ] && [ -x "$prog" ]; then
    echo "$prog"
    return 0
  fi
  if [ -x "$SIDEBIN_DIR/lastdbd" ]; then
    echo "$SIDEBIN_DIR/lastdbd"
    return 0
  fi
  command -v lastdbd 2>/dev/null || true
}

lat_op_within_bar() {
  # Wrapper: default hot-vs-hot. Prefer lat_op_like_to_like_within_bar.
  local op="$1" cand="$2" base="$3" c_th="${4:-hot}" b_th="${5:-hot}"
  local out rc=0
  export LASTDB_PROBE_LAT_FLOOR_MS="${LAT_FLOOR_MS}"
  export LASTDB_PROBE_LAT_RATIO="${LAT_RATIO}"
  export LASTDB_PROBE_LAT_ABS_MAX_MS="${LAT_ABS_MAX_MS}"
  out="$(lat_op_like_to_like_within_bar "$op" "$cand" "$base" "$c_th" "$b_th")" || rc=$?
  if [ -n "$out" ]; then
    case "$out" in
      *' RED:'*) log "$out" ;;
      *'mixed thermal'*) log "$out" ;;
      *WATCH*|*pre-existing*) warn "$out" ;;
      *) log "$out" ;;
    esac
  fi
  return "$rc"
}

# Leaf must stay short: the node refuses a data dir over 82 bytes (103-byte
# sockaddr_un limit minus socket name + atomic temp sibling). $$ keeps uniqueness.
clone_probe_home() {
  local label="$1" copy
  mkdir -p "$PROBE_ROOT"
  copy="$PROBE_ROOT/mp-${label}-$$"
  rm -rf "$copy"
  cp -cR "$PRIMARY_HOME" "$copy" 2>/dev/null || true
  if [ ! -d "$copy" ] || [ ! -f "$copy/identity.key" ] || [ ! -d "$copy/data" ]; then
    warn "$label metrics probe: CoW clone incomplete"
    rm -rf "$copy" 2>/dev/null || true
    return 1
  fi
  rm -f "$copy/cloud_sync.json" "$copy/data/"*.sock 2>/dev/null || true
  printf '%s\n' "$copy"
}

# Start lastdbd on $1=bin $2=copy $3=label. Sets LAST_PROBE_PID/SOCK/BLOG/BOOT.
start_probe_node() {
  local bin="$1" copy="$2" label="$3"
  local blog sock pid uh i
  local env_pairs=()
  blog="$copy.boot.log"
  sock="$copy/data/folddb.sock"
  while IFS= read -r line; do
    [ -n "$line" ] && env_pairs+=("$line")
  done <<EOF_ENV
$(live_lastdb_env_pairs)
EOF_ENV
  if [ "${#env_pairs[@]}" -gt 0 ]; then
    log "$label metrics probe: mirroring live env: ${env_pairs[*]}"
  fi
  env -u SENTRY_DSN -u FOLD_SENTRY_DSN ${env_pairs[@]+"${env_pairs[@]}"} \
    "$bin" --data-dir "$copy" >"$blog" 2>&1 &
  pid=$!
  uh=""
  for i in $(seq 1 300); do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "$label metrics probe: node exited during boot ($(tail -2 "$blog" 2>/dev/null | tr '\n' ' '))"
      rm -rf "$copy" "$blog" 2>/dev/null || true
      return 1
    fi
    if [ -S "$sock" ]; then
      uh="$(curl -sS --max-time 3 --unix-socket "$sock" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/system/auto-identity 2>/dev/null | jq -r '.user_hash // empty' 2>/dev/null || true)"
      [ -n "$uh" ] && break
    fi
    sleep 1
  done
  if [ -z "$uh" ]; then
    warn "$label metrics probe: identity not ready in 300s"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -rf "$copy" "$blog" 2>/dev/null || true
    return 1
  fi
  log "$label metrics probe: identity ready after ${i}s"
  LAST_PROBE_PID="$pid"
  LAST_PROBE_SOCK="$sock"
  LAST_PROBE_BLOG="$blog"
  LAST_PROBE_BOOT="$i"
  return 0
}

stop_probe_node() {
  local pid="$1" copy="$2" blog="$3"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  sleep 2
  kill -9 "$pid" 2>/dev/null || true
  rm -rf "$copy" "$blog" 2>/dev/null || true
}

# Boot candidate and baseline CoWs together. Cold fetch = first query after
# identity-ready. Hot = median after settle + one discarded warmup. Write is
# hot-only. Writes cand/base metric files with lat_cold_* / lat_hot_* keys.
probe_like_to_like_metrics() {
  local cand_bin="$1" base_bin="$2" cand_out="$3" base_out="$4"
  local c_copy b_copy c_pid b_pid c_sock b_sock c_blog b_blog c_boot b_boot
  local max_rss rss i
  local c_cold_pt=-1 b_cold_pt=-1 c_cold_sc=-1 b_cold_sc=-1
  local c_hot_pt=-1 b_hot_pt=-1 c_hot_sc=-1 b_hot_sc=-1 c_hot_wr=-1 b_hot_wr=-1

  c_copy="$(clone_probe_home c)" || return 1
  if [ -n "$base_bin" ] && [ -x "$base_bin" ]; then
    b_copy="$(clone_probe_home b)" || {
      rm -rf "$c_copy" 2>/dev/null || true
      return 1
    }
  else
    b_copy=""
  fi

  if ! start_probe_node "$cand_bin" "$c_copy" "candidate"; then
    rm -rf "$b_copy" 2>/dev/null || true
    return 1
  fi
  c_pid="$LAST_PROBE_PID"
  c_sock="$LAST_PROBE_SOCK"
  c_blog="$LAST_PROBE_BLOG"
  c_boot="$LAST_PROBE_BOOT"

  b_pid=""
  b_sock=""
  b_blog=""
  b_boot=""
  if [ -n "$b_copy" ]; then
    if start_probe_node "$base_bin" "$b_copy" "baseline"; then
      b_pid="$LAST_PROBE_PID"
      b_sock="$LAST_PROBE_SOCK"
      b_blog="$LAST_PROBE_BLOG"
      b_boot="$LAST_PROBE_BOOT"
    else
      warn "latency: baseline probe failed to boot — applying absolute ceiling only"
      b_copy=""
    fi
  fi

  max_rss=0
  sample_cand_rss() {
    if [ -n "$c_pid" ] && kill -0 "$c_pid" 2>/dev/null; then
      rss="$(rss_mb_of_pid "$c_pid")"
      if [ "$rss" -gt "$max_rss" ] 2>/dev/null; then max_rss="$rss"; fi
    fi
  }

  if [ "$LAT_SKIP" != "1" ]; then
    # Cold: first query after identity-ready, interleaved, no settle yet.
    if [ -n "$b_sock" ] && [ $((RANDOM % 2)) -eq 0 ]; then
      b_cold_pt="$(measure_op_once_ms op_lat_point "$b_sock" "baseline cold point-read")"
      c_cold_pt="$(measure_op_once_ms op_lat_point "$c_sock" "candidate cold point-read")"
    else
      c_cold_pt="$(measure_op_once_ms op_lat_point "$c_sock" "candidate cold point-read")"
      if [ -n "$b_sock" ]; then
        b_cold_pt="$(measure_op_once_ms op_lat_point "$b_sock" "baseline cold point-read")"
      fi
    fi
    sample_cand_rss
    if command -v kanban >/dev/null 2>&1; then
      if [ -n "$b_copy" ] && [ $((RANDOM % 2)) -eq 0 ]; then
        b_cold_sc="$(measure_op_once_ms op_lat_scan "$b_copy" "baseline cold scan")"
        c_cold_sc="$(measure_op_once_ms op_lat_scan "$c_copy" "candidate cold scan")"
      else
        c_cold_sc="$(measure_op_once_ms op_lat_scan "$c_copy" "candidate cold scan")"
        if [ -n "$b_copy" ]; then
          b_cold_sc="$(measure_op_once_ms op_lat_scan "$b_copy" "baseline cold scan")"
        fi
      fi
      sample_cand_rss
    else
      warn "latency: kanban CLI not on PATH — scan op unmeasured"
    fi

    log "latency: settling ${RSS_SETTLE_SECS}s then discarding one warmup sample per node"
    sleep "$RSS_SETTLE_SECS"
    discard_op_warmup op_lat_point "$c_sock" "candidate hot warmup point"
    [ -n "$b_sock" ] && discard_op_warmup op_lat_point "$b_sock" "baseline hot warmup point"
    if command -v kanban >/dev/null 2>&1; then
      discard_op_warmup op_lat_scan "$c_copy" "candidate hot warmup scan"
      [ -n "$b_copy" ] && discard_op_warmup op_lat_scan "$b_copy" "baseline hot warmup scan"
    fi

    c_hot_pt="$(measure_op_median_ms op_lat_point "$c_sock" "candidate hot point-read")"
    [ -n "$b_sock" ] && b_hot_pt="$(measure_op_median_ms op_lat_point "$b_sock" "baseline hot point-read")"
    sample_cand_rss
    if command -v kanban >/dev/null 2>&1; then
      c_hot_sc="$(measure_op_median_ms op_lat_scan "$c_copy" "candidate hot scan")"
      [ -n "$b_copy" ] && b_hot_sc="$(measure_op_median_ms op_lat_scan "$b_copy" "baseline hot scan")"
      sample_cand_rss
    fi
    if command -v brain >/dev/null 2>&1; then
      c_hot_wr="$(measure_op_median_ms op_lat_write "$c_copy" "candidate hot write")"
      [ -n "$b_copy" ] && b_hot_wr="$(measure_op_median_ms op_lat_write "$b_copy" "baseline hot write")"
      sample_cand_rss
    else
      warn "latency: brain CLI not on PATH — write op unmeasured"
    fi
  else
    warn "latency bar SKIPPED (LAT_SKIP=1) — RSS sampled after settle only"
    sleep "$RSS_SETTLE_SECS"
  fi

  for i in $(seq 1 "$RSS_SAMPLE_SECS"); do
    if ! kill -0 "$c_pid" 2>/dev/null; then
      warn "candidate metrics probe: node died during RSS sample window"
      break
    fi
    sample_cand_rss
    sleep 1
  done

  if ! kill -0 "$c_pid" 2>/dev/null; then
    stop_probe_node "$c_pid" "$c_copy" "$c_blog"
    stop_probe_node "$b_pid" "$b_copy" "$b_blog"
    return 1
  fi

  # Row-count bar (never skipped by LAT_SKIP — this is a correctness bar, not a
  # speed bar). Both nodes serve the same CoW data and are still up here.
  c_rows_pt="$(op_rows_point "$c_sock")"
  b_rows_pt="-1"
  [ -n "$b_sock" ] && b_rows_pt="$(op_rows_point "$b_sock")"
  c_rows_sc="-1"
  b_rows_sc="-1"
  if command -v kanban >/dev/null 2>&1; then
    c_rows_sc="$(op_rows_scan "$c_copy")"
    [ -n "$b_copy" ] && b_rows_sc="$(op_rows_scan "$b_copy")"
  else
    warn "rowcount: kanban CLI not on PATH — scan row count unmeasured"
  fi
  log "row counts: point cand=${c_rows_pt} base=${b_rows_pt} · scan cand=${c_rows_sc} base=${b_rows_sc}"

  {
    echo "boot_secs=$c_boot"
    echo "peak_rss_mb=$max_rss"
    echo "lat_cold_point_ms=$c_cold_pt"
    echo "lat_cold_scan_ms=$c_cold_sc"
    echo "lat_hot_point_ms=$c_hot_pt"
    echo "lat_hot_scan_ms=$c_hot_sc"
    echo "lat_hot_write_ms=$c_hot_wr"
    echo "lat_point_ms=$c_hot_pt"
    echo "lat_scan_ms=$c_hot_sc"
    echo "lat_write_ms=$c_hot_wr"
    echo "rows_point=$c_rows_pt"
    echo "rows_scan=$c_rows_sc"
  } >"$cand_out"
  if [ -n "$base_out" ]; then
    {
      echo "boot_secs=${b_boot:--1}"
      echo "lat_cold_point_ms=$b_cold_pt"
      echo "lat_cold_scan_ms=$b_cold_sc"
      echo "lat_hot_point_ms=$b_hot_pt"
      echo "lat_hot_scan_ms=$b_hot_sc"
      echo "lat_hot_write_ms=$b_hot_wr"
      echo "lat_point_ms=$b_hot_pt"
      echo "lat_scan_ms=$b_hot_sc"
      echo "lat_write_ms=$b_hot_wr"
      echo "rows_point=$b_rows_pt"
      echo "rows_scan=$b_rows_sc"
    } >"$base_out"
  fi
  log "candidate metrics: boot_s=${c_boot} peak_rss_mb=${max_rss} cold_point_ms=${c_cold_pt} cold_scan_ms=${c_cold_sc} hot_point_ms=${c_hot_pt} hot_scan_ms=${c_hot_sc} hot_write_ms=${c_hot_wr}"
  log "baseline metrics: boot_s=${b_boot:--} cold_point_ms=${b_cold_pt} cold_scan_ms=${b_cold_sc} hot_point_ms=${b_hot_pt} hot_scan_ms=${b_hot_sc} hot_write_ms=${b_hot_wr}"

  stop_probe_node "$c_pid" "$c_copy" "$c_blog"
  stop_probe_node "$b_pid" "$b_copy" "$b_blog"
  return 0
}

enforce_rss_under_limit() {
  # $1 = rss_mb, $2 = context label (probe|live)
  local rss="$1" ctx="$2" limit fail_at
  limit="$(resolve_rss_limit_mb)"
  fail_at="$(rss_fail_threshold_mb "$limit")"
  if ! [ "$rss" -ge 0 ] 2>/dev/null; then
    warn "RSS $ctx: could not measure rss_mb (got '$rss'); treating as RED"
    return 1
  fi
  if [ "$rss" -ge "$fail_at" ]; then
    log "RSS $ctx RED: rss_mb=${rss} >= fail_at=${fail_at} (limit=${limit}, headroom=${RSS_HEADROOM_PCT}%)"
    return 1
  fi
  log "RSS $ctx GREEN: rss_mb=${rss} < fail_at=${fail_at} (limit=${limit})"
  return 0
}


# --- venue: sidebin (LaunchAgent) vs brew ------------------------------------

detect_live_venue() {
  # Sets: VENUE (sidebin|brew), LIVE_BIN, SIDEBIN_DIR (may refine)
  VENUE=""
  LIVE_BIN=""
  local prog=""

  if [ -f "$LAUNCHD_PLIST" ]; then
    prog="$(plutil -extract ProgramArguments.0 raw "$LAUNCHD_PLIST" 2>/dev/null || true)"
    if [ -n "$prog" ]; then
      LIVE_BIN="$prog"
      case "$prog" in
        */Cellar/lastdb/*|*/opt/lastdb/*|*/homebrew/*/lastdbd)
          VENUE="brew"
          ;;
        *)
          VENUE="sidebin"
          SIDEBIN_DIR="$(dirname "$prog")"
          ;;
      esac
    fi
  fi

  if [ -z "$VENUE" ]; then
    if brew list --formula edgevector/lastdb/lastdb >/dev/null 2>&1 \
      || brew list --formula lastdb >/dev/null 2>&1; then
      VENUE="brew"
      LIVE_BIN="$(command -v lastdbd 2>/dev/null || true)"
    elif [ -x "$SIDEBIN_DIR/lastdbd" ]; then
      VENUE="sidebin"
      LIVE_BIN="$SIDEBIN_DIR/lastdbd"
    else
      die "cannot detect live venue (no LaunchAgent ProgramArguments, no brew formula, no $SIDEBIN_DIR/lastdbd)"
    fi
  fi

  # Explicit --candidate never uses brew Cellar install; if launchd points at
  # sidebin (Tom's machine), stay sidebin even if formula appears later.
  if [ -n "${CANDIDATE_BIN:-}" ] && [ -x "$SIDEBIN_DIR/lastdbd" ]; then
    case "${LIVE_BIN:-}" in
      */opt/lastdb/*|*/Cellar/lastdb/*) ;;
      *)
        VENUE="sidebin"
        LIVE_BIN="${LIVE_BIN:-$SIDEBIN_DIR/lastdbd}"
        SIDEBIN_DIR="$(dirname "$LIVE_BIN")"
        ;;
    esac
  fi

  log "live venue: $VENUE"
  log "live binary: ${LIVE_BIN:-unknown}"
  [ "$VENUE" = "sidebin" ] && log "sidebin dir: $SIDEBIN_DIR"
  [ "$VENUE" = "sidebin" ] && log "launchd label: $LAUNCHD_LABEL"
}

# A sidebin live install that cannot name the real launchd job cannot restart
# the primary. Refuse rather than reload into the void — the old daemon keeps
# serving and every downstream health check passes, so this fails silent.
assert_launchd_label_usable() {
  [ "$VENUE" = "sidebin" ] || return 0
  case "$LAUNCHD_LABEL" in
    com.REPLACE.*)
      die "unresolved launchd label ($LAUNCHD_LABEL) — cannot restart primary. Set LASTDB_LAUNCHD_LABEL to the real job (see: launchctl list | grep lastdbd)" ;;
  esac
  if [ "$LAUNCHD_LABEL_RESOLVED" != "1" ]; then
    die "could not resolve the primary launchd label; refusing sidebin live install"
  fi
  if ! launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$LAUNCHD_LABEL"; then
    die "launchd label $LAUNCHD_LABEL is not a loaded job — job reload would target the wrong service"
  fi
  if [ ! -f "$LAUNCHD_PLIST" ]; then
    die "primary LaunchAgent plist missing ($LAUNCHD_PLIST) for resolved label $LAUNCHD_LABEL"
  fi
  log "launchd label verified loaded: $LAUNCHD_LABEL"
}

ensure_primary_launchd_rss_limit() {
  local limit current
  if [ ! -f "$LAUNCHD_PLIST" ]; then
    warn "primary LaunchAgent plist missing ($LAUNCHD_PLIST); cannot stamp LASTDBD_RSS_LIMIT_MB before job reload"
    return 0
  fi
  limit="$(resolve_live_rss_limit_mb)"
  if ! [ "$limit" -gt 0 ] 2>/dev/null; then
    die "invalid LASTDBD_RSS_LIMIT_MB resolved for live LaunchAgent: $limit"
  fi
  current="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB' "$LAUNCHD_PLIST" 2>/dev/null || true)"
  if [ "$current" = "$limit" ]; then
    log "primary LaunchAgent LASTDBD_RSS_LIMIT_MB already $limit"
    return 0
  fi
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$LAUNCHD_PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "$LAUNCHD_PLIST"
  if [ -n "$current" ]; then
    /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB $limit" "$LAUNCHD_PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:LASTDBD_RSS_LIMIT_MB string $limit" "$LAUNCHD_PLIST"
  fi
  log "stamped primary LaunchAgent LASTDBD_RSS_LIMIT_MB=$limit (was ${current:-unset})"
}

live_install_sidebin() {
  local dest="$SIDEBIN_DIR"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  [ -x "$CANDIDATE_BIN" ] || die "candidate not executable: $CANDIDATE_BIN"
  [ -x "$CANDIDATE_CLI_BIN" ] || die "candidate sibling lastdb CLI not executable: $CANDIDATE_CLI_BIN"
  mkdir -p "$dest"

  # Single-flight lock
  local lock="$dest/.cutover.lock"
  if [ -f "$lock" ]; then
    local age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 600 ]; then
      die "cutover lock present ($lock, age ${age}s) — another upgrade in flight?"
    fi
    warn "stale cutover lock (age ${age}s); removing"
    rm -f "$lock"
  fi
  echo "$$ $CAND_VER $ts" >"$lock"
  # Release on ANY exit path. Recurrences 2 and 3 both leaked this lock because
  # `die` exits before the rm at the end of this function, and the next run then
  # refused to start for 10 minutes behind a lock whose owner was long gone.
  CUTOVER_LOCK="$lock"

  if [ -x "$dest/lastdbd" ]; then
    cp -a "$dest/lastdbd" "$dest/lastdbd.bak-pre-${CAND_VER}-${ts}"
    log "backed up live lastdbd → lastdbd.bak-pre-${CAND_VER}-${ts}"
  fi
  cp -a "$CANDIDATE_BIN" "$dest/lastdbd.new"
  chmod +x "$dest/lastdbd.new"

  if [ -x "$dest/lastdb" ]; then
    cp -a "$dest/lastdb" "$dest/lastdb.bak-pre-${CAND_VER}-${ts}" 2>/dev/null || true
  fi
  cp -a "$CANDIDATE_CLI_BIN" "$dest/lastdb.new"
  chmod +x "$dest/lastdb.new"

  # Atomic-ish swap (same directory rename)
  mv -f "$dest/lastdbd.new" "$dest/lastdbd"
  mv -f "$dest/lastdb.new" "$dest/lastdb"
  log "installed candidate into $dest/{lastdb,lastdbd}"

  ensure_primary_launchd_rss_limit

  local uid
  uid="$(id -u)"
  CUTOVER_T0="$(date +%s)"
  if ! lastdb_launchd_reload_job \
    launchctl "gui/${uid}" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"; then
    page_human "safe-upgrade: primary lastdbd is UNLOADED — bootstrap retries exhausted for ${LAUNCHD_LABEL}. Recover: launchctl bootstrap gui/${uid} ${LAUNCHD_PLIST}"
    die "launchd job-definition reload failed after bootstrap retries; the primary is UNLOADED. Recover: launchctl bootstrap gui/${uid} ${LAUNCHD_PLIST} then launchctl print gui/${uid}/${LAUNCHD_LABEL}"
  fi
  RESTART_INTENT_START_REQUESTED=1

  # Wait for a LIVE listener + /health. A leftover folddb.sock inode is
  # still `-S` after bootout; waiting only for the inode reports
  # "socket up after 0s" and then the post-check curls a dead listener
  # (2026-08-26: bootstrap EIO, leftover sock dated hours earlier, RED).
  # Unlink the leftover only when nothing holds it. Recovery after an
  # unclean prior exit can take 60-90s+. Starting a SECOND lastdbd
  # against the live home while the launchd one is still booting is the
  # 2026-07-17 boot storm (card lastdb-safe-upgrade-cutover-supervisor-race).
  # While the launchd job exists, KeepAlive owns respawns — NEVER
  # direct-start a rival.
  local wait_secs="${LASTDB_CUTOVER_SOCKET_WAIT_SECS:-180}"
  local sock_wait_out="" sock_wait_rc=0
  set +e
  sock_wait_out="$(wait_for_live_unix_socket_health "$PRIMARY_SOCK" "$wait_secs" 2>&1)"
  sock_wait_rc=$?
  set -e
  if [ -n "$sock_wait_out" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && log "$line"
    done <<< "$sock_wait_out"
  fi
  if [ "$sock_wait_rc" -eq 0 ]; then
    :
  elif lastdb_launchd_job_loaded launchctl "gui/${uid}/${LAUNCHD_LABEL}"; then
    warn "listener/health still missing after ${wait_secs}s but launchd job is loaded — NOT direct-starting a second daemon (lock fight). Inspect: launchctl print gui/${uid}/${LAUNCHD_LABEL}; tail ~/.lastdb/last_boot_error.txt"
  else
    # LASTDB_LAUNCHD_RELOAD=ok can still leave the job unloaded by the end of
    # the 180s wait (EIO race, then KeepAlive never took the process). Retry
    # bootstrap before any nohup --data-dir start so KeepAlive owns lastdbd.
    # decision-2026-08-23-unattended-lastdbd-bootstrap-self-heal.
    warn "no launchd job and no healthy socket after ${wait_secs}s; retrying LaunchAgent bootstrap so KeepAlive owns lastdbd"
    if lastdb_launchd_reload_job \
      launchctl "gui/${uid}" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"; then
      set +e
      sock_wait_out="$(wait_for_live_unix_socket_health "$PRIMARY_SOCK" "$wait_secs" 2>&1)"
      sock_wait_rc=$?
      set -e
      if [ -n "$sock_wait_out" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] && log "$line"
        done <<< "$sock_wait_out"
      fi
    else
      warn "bootstrap retry exhausted; job still unloaded"
    fi
    if [ "$sock_wait_rc" -ne 0 ] \
      && ! lastdb_launchd_job_loaded launchctl "gui/${uid}/${LAUNCHD_LABEL}"; then
      warn "no launchd job after bootstrap retry; starting $dest/lastdbd --data-dir $PRIMARY_HOME once (listener only — not GREEN)"
      nohup "$dest/lastdbd" --data-dir "$PRIMARY_HOME" \
        >>"${LASTDB_MANUAL_LOG:-/opt/homebrew/var/log/lastdb/lastdbd.manual-cutover.log}" 2>&1 &
      set +e
      sock_wait_out="$(wait_for_live_unix_socket_health "$PRIMARY_SOCK" "$wait_secs" 2>&1)"
      sock_wait_rc=$?
      set -e
      if [ -n "$sock_wait_out" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] && log "$line"
        done <<< "$sock_wait_out"
      fi
    elif [ "$sock_wait_rc" -ne 0 ]; then
      warn "listener/health still missing after bootstrap retry but launchd job is loaded — NOT direct-starting a second daemon (lock fight). Inspect: launchctl print gui/${uid}/${LAUNCHD_LABEL}; tail ~/.lastdb/last_boot_error.txt"
    fi
  fi
  rm -f "$lock"
}

resolve_live_primary_pid() {
  local pid=""
  if [ -S "$PRIMARY_SOCK" ]; then
    pid="$(lsof -t "$PRIMARY_SOCK" 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$pid" ]; then
    pid="$(pgrep -f "$SIDEBIN_DIR/lastdbd\$|$SIDEBIN_DIR/lastdbd " 2>/dev/null | head -1 || true)"
  fi
  printf '%s\n' "$pid"
}

live_install_brew() {
  if ! brew list --formula edgevector/lastdb/lastdb >/dev/null 2>&1 \
    && ! brew list --formula lastdb >/dev/null 2>&1; then
    die "venue=brew but formula edgevector/lastdb/lastdb is not installed — refuse brew upgrade (primary may be sidebin; pass --candidate and use sidebin path)"
  fi
  if brew services list 2>/dev/null | awk '$1=="lastdb"{print $2}' | grep -q started; then
    brew services stop lastdb || warn "brew services stop lastdb failed"
    sleep 2
  fi
  brew upgrade edgevector/lastdb/lastdb 2>&1 \
    || die "brew upgrade failed (primary may still be running if brew was not supervising it). Check launchd/sidebin. Backup: $BACKUP"
  brew services start lastdb || die "brew services start lastdb failed"
  RESTART_INTENT_START_REQUESTED=1
}

# --- preflight ---------------------------------------------------------------

OWNER_LOCK_MODE="live"
[ "$PROBE_ONLY" -eq 1 ] && OWNER_LOCK_MODE="probe-only"
if ! safe_upgrade_owner_lock_acquire_wait \
    "$OWNER_LOCK_DIR" "$OWNER_LOCK_TOKEN" "$$" "${CANDIDATE_BIN:-${TARGET_VERSION:-auto}}" "$OWNER_LOCK_MODE"; then
  die "another LastDB safe-upgrade process owns the host-wide safety lane"
fi
OWNER_LOCK_HELD=1
log "owner lock acquired: $OWNER_LOCK_DIR pid=$$ mode=$OWNER_LOCK_MODE"

[ -d "$PRIMARY_HOME" ] || die "primary home missing: $PRIMARY_HOME"
[ -f "$PRIMARY_HOME/identity.key" ] || die "no identity.key in $PRIMARY_HOME — refusing upgrade"
[ -x "$SMOKE_SH" ] || die "smoke harness missing: $SMOKE_SH"

if [ -x "${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}/lastdbd" ]; then
  CURRENT_VER="$("${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}/lastdbd" --version 2>/dev/null | awk '{print $NF}' || true)"
else
  CURRENT_VER="$(lastdbd --version 2>/dev/null | awk '{print $NF}' || true)"
fi
[ -n "$CURRENT_VER" ] || die "cannot read current lastdbd --version (is brew lastdb installed?)"
log "current lastdbd: $CURRENT_VER"
log "primary home:    $PRIMARY_HOME ($(du -sh "$PRIMARY_HOME" 2>/dev/null | awk '{print $1}'))"

if [ -S "$PRIMARY_SOCK" ]; then
  if ! curl -sS --max-time 5 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/health \
    | grep -q '"status":"ok"'; then
    die "primary socket exists but /health is not ok — fix the live brain before upgrading"
  fi
  log "primary /health: ok"
else
  warn "primary socket not present — service may be stopped; continuing with offline home"
fi

# --- resolve candidate binary ------------------------------------------------

# Probe copies boot live nodes with Unix sockets under WORK. A routinesd
# TMPDIR under $HOME/.routines/runs/<run>/scratch is deep enough to push the
# probe socket path over the 103-byte sockaddr_un limit (observed 2026-08-23:
# "data dir ... is too deep to host a Unix control socket"), so the
# TMPDIR-derived WORK base gets the same off-HOME fallback as ROLLBACK_ROOT.
# Darwin TMPDIR under /var/folders/... is also too long (observed 2026-08-26:
# grok-goal scratch 56-byte prefix → folddb-full.sock 133 bytes). Mini refuses
# a data dir over 82 bytes. Fall back to /tmp when the prefix cannot fit
# /lastdb-safe-upgrade.XXXXXX/probes/smoke/copy-<epoch>-<pid>/data.
_work_tmp="${TMPDIR:-/tmp}"
case "$(cd "$_work_tmp" 2>/dev/null && pwd -P || printf '%s' "$_work_tmp")" in
  "$_rollback_home_real"|"$_rollback_home_real"/*) _work_tmp="/tmp" ;;
esac
# 70 bytes reserved for /lastdb-safe-upgrade.XXXXXX/probes/smoke/copy-.../data
if [ "${#_work_tmp}" -gt 12 ]; then
  log "probe WORK prefix ${_work_tmp} is ${#_work_tmp} bytes; using /tmp for sockaddr_un"
  _work_tmp="/tmp"
fi
# An inherited LASTDB_PROBE_ROOT from a prior failed run can be equally long.
if [ -n "$PROBE_ROOT" ] && [ "${#PROBE_ROOT}" -gt 40 ]; then
  warn "ignoring inherited LASTDB_PROBE_ROOT (${#PROBE_ROOT} bytes) — too deep for Unix sockets"
  PROBE_ROOT=""
fi
WORK="$(mktemp -d "${_work_tmp}/lastdb-safe-upgrade.XXXXXX")"
[ -n "$PROBE_ROOT" ] || PROBE_ROOT="$WORK/probes"
export LASTDB_PROBE_ROOT="$PROBE_ROOT"
CAND_DIR="$WORK/cand"
mkdir -p "$CAND_DIR"

fetch_tap_tarball() {
  local ver="$1" tag url
  case "$ver" in
    v*) tag="$ver"; ver="${ver#v}" ;;
    *) tag="v$ver" ;;
  esac
  url="https://github.com/${TAP_REPO}/releases/download/${tag}/lastdb-aarch64-apple-darwin.tar.gz"
  log "fetching candidate $tag from $url"
  curl -fsSL -o "$WORK/cand.tar.gz" "$url" || die "download failed: $url"
  tar -xzf "$WORK/cand.tar.gz" -C "$CAND_DIR"
  [ -x "$CAND_DIR/lastdbd" ] || die "tarball missing lastdbd"
  CANDIDATE_BIN="$CAND_DIR/lastdbd"
  TARGET_VERSION="$ver"
}

if [ -n "$CANDIDATE_BIN" ]; then
  [ -x "$CANDIDATE_BIN" ] || die "candidate not executable: $CANDIDATE_BIN"
  TARGET_VERSION="$("$CANDIDATE_BIN" --version 2>/dev/null | awk '{print $NF}' || echo unknown)"
  log "using explicit candidate: $CANDIDATE_BIN ($TARGET_VERSION)"
elif [ -n "$TARGET_VERSION" ]; then
  fetch_tap_tarball "$TARGET_VERSION"
else
  log "brew update (resolve latest stable formula)…"
  brew update >/dev/null 2>&1 || warn "brew update failed; using cached formula metadata"
  # Prefer formula stable version from brew
  STABLE="$(brew info --json=v2 edgevector/lastdb/lastdb 2>/dev/null \
    | jq -r '.formulae[0].versions.stable // empty' 2>/dev/null || true)"
  if [ -z "$STABLE" ]; then
    STABLE="$(brew info edgevector/lastdb/lastdb 2>/dev/null | awk -F'→' '/stable/{gsub(/[^0-9.].*/,"",$2); print $2; exit}' | tr -d ' ')"
  fi
  [ -n "$STABLE" ] || die "could not resolve stable formula version from brew"
  if [ "$STABLE" = "$CURRENT_VER" ]; then
    log "already on stable $CURRENT_VER — nothing to upgrade"
    echo "VERDICT: ALREADY_CURRENT"
    echo "SUMMARY: lastdbd $CURRENT_VER is already the brew stable version."
    exit 0
  fi
  log "brew stable is $STABLE (installed $CURRENT_VER)"
  fetch_tap_tarball "$STABLE"
fi

CAND_VER="$("$CANDIDATE_BIN" --version 2>/dev/null | awk '{print $NF}' || true)"
[ -n "$CAND_VER" ] || die "candidate --version failed"
log "candidate version: $CAND_VER"

CANDIDATE_CLI_BIN="$(lastdb_sibling_cli_for_daemon "$CANDIDATE_BIN")"
PAIR_OUT=""
set +e
PAIR_OUT="$(assert_lastdb_binary_pair_ok "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN" "$CAND_VER" "candidate artifact" 2>&1)"
PAIR_RC=$?
set -e
if [ -n "$PAIR_OUT" ]; then
  while IFS= read -r line; do
    case "$line" in
      RED:*) log "binary pair $line" ;;
      *)     log "binary pair: $line" ;;
    esac
  done <<< "$PAIR_OUT"
fi
if [ "$PAIR_RC" -ne 0 ]; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER failed the binary-pair bar — lastdb and lastdbd must come from the same artifact"
  echo "CANDIDATE_DAEMON: $CANDIDATE_BIN"
  echo "CANDIDATE_CLI:    $CANDIDATE_CLI_BIN"
  echo "NEXT: build/package both lastdb and lastdbd from the same source revision; never promote a daemon-only artifact."
  exit 1
fi

if [ "$CAND_VER" = "$CURRENT_VER" ] && [ "$PROBE_ONLY" -eq 0 ]; then
  log "candidate matches current; no upgrade needed"
  echo "VERDICT: ALREADY_CURRENT"
  exit 0
fi

# --- 0) candidate class bar (before multi-GB rollback clone) -----------------
# Incident 2026-08-01: agent safe-upgraded
# ~/.fkanban/worktrees/…/target/debug/lastdbd (0.23.2-258-…-dirty) — exclusive
# CoW latency looked fine; live contended lists hit multi-second→60s until bak.
# Refuse debug / dirty / oversized candidates up front (brain:
# incident-20260801-debug-worktree-lastdbd-primary-cutover-latency).
BASELINE_FOR_CLASS="$(resolve_baseline_bin 2>/dev/null || true)"
CLASS_OUT=""
set +e
CLASS_OUT="$(assert_candidate_class_ok "$CANDIDATE_BIN" "$CAND_VER" "$BASELINE_FOR_CLASS" 2>&1)"
CLASS_RC=$?
set -e
if [ -n "$CLASS_OUT" ]; then
  while IFS= read -r line; do
    case "$line" in
      WARN:*) warn "${line#WARN: }" ;;
      RED:*)  log "candidate class $line" ;;
      *)      log "candidate class: $line" ;;
    esac
  done <<< "$CLASS_OUT"
fi
if [ "$CLASS_RC" -ne 0 ]; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER fails the candidate-class bar (debug path / dirty version / size vs incumbent) — incident 2026-08-01"
  echo "CANDIDATE: $CANDIDATE_BIN"
  echo "BASELINE:  ${BASELINE_FOR_CLASS:-none}"
  echo "NEXT:      cargo build --release -p lastdb_node (or release artifact from origin/main); never target/debug or -dirty. Overrides LASTDB_ALLOW_DEBUG_CANDIDATE / LASTDB_ALLOW_DIRTY_CANDIDATE / LASTDB_ALLOW_LARGE_CANDIDATE require Tom clearance."
  exit 1
fi
log "candidate class GREEN: path/version/size ok (vs baseline ${BASELINE_FOR_CLASS:-none})"

# --- 1) ephemeral CoW rollback point -----------------------------------------

prepare_rollback_root
kept="$(newest_routine_rollback_point)"
if [ -n "$kept" ] && backup_essentials_ok "$kept" && backup_data_is_not_live "$kept"; then
  BACKUP="$kept"
  ROLLBACK_READY=1
  log "STEP 1/4: reused newest rollback point → $BACKUP"
  log "rollback: skipped cp -cR; kept newest point from a prior driver-ended step"
else
  if [ -n "$kept" ]; then
    log "rollback: newest point unusable; cloning a fresh one"
    rm -rf "$kept"
  fi
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP="$ROLLBACK_ROOT/pre-${CAND_VER}-from-${CURRENT_VER}-${TS}"
  # Prefer APFS clone for speed. A *live* primary races with the copy:
  #   - UDS sockets under data/*.sock (not copyable)
  #   - CAS blob files that vanish mid-walk
  # Those produce non-zero `cp` exit even when identity + store data are cloned.
  # Treat clone as OK when essential files land despite socket/blob races. Never
  # fall back to a full rsync copy: upgrade safety must not buy itself with disk.
  log "STEP 1/4: ephemeral CoW rollback point → $BACKUP"
  set +e
  cp -cR "$PRIMARY_HOME" "$BACKUP" 2>"$WORK/rollback-clone.err"
  CP_RC=$?
  set -e
  backup_essentials_ok "$BACKUP" \
    || die "CoW rollback clone incomplete (cp exit=$CP_RC); refusing full-copy fallback; see $WORK/rollback-clone.err"
  ROLLBACK_READY=1
  log "rollback: APFS clone ready (cp -cR exit=$CP_RC; live sockets/vanished blobs tolerated)"
  if [ "$CP_RC" -ne 0 ] && [ -s "$WORK/rollback-clone.err" ]; then
    log "rollback: non-fatal cp notes (first 5 lines):"
    head -5 "$WORK/rollback-clone.err" | while IFS= read -r line; do log "  $line"; done
  fi
  [ ! -L "$BACKUP" ] || die "rollback point resolved to a symlink (unsafe)"
  backup_data_is_not_live "$BACKUP" || die "rollback point data dir aliases live primary"
  log "rollback point ok ($(du -sh "$BACKUP" 2>/dev/null | awk '{print $1}'))"
fi

# --- 2) probe candidate on a throwaway CoW of the primary --------------------

log "STEP 2/4: probe candidate $CAND_VER against CoW copy of primary (never live home)"
# The smoke harness clones PRIMARY_HOME itself and boots BIN. We only pass BIN.
set +e
SMOKE_OUT="$WORK/smoke.out"
LASTDB_PROBE_ROOT="$PROBE_ROOT/smoke" \
LASTDB_SMOKE_FAIL_LOG_DIR="$BACKUP/.safe-upgrade" \
BIN="$CANDIDATE_BIN" bash "$SMOKE_SH" >"$SMOKE_OUT" 2>&1
SMOKE_RC=$?
set -e
cat "$SMOKE_OUT"
if [ "$SMOKE_RC" -ne 0 ] || ! grep -q 'VERDICT: GREEN' "$SMOKE_OUT"; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER failed real-data probe (exit $SMOKE_RC)"
  echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
  echo "NEXT:   do NOT brew upgrade; file a release-blocker; restore from backup only if primary is already broken"
  exit 1
fi
log "data-plane probe GREEN for candidate $CAND_VER"

# --- 2b) CAS mutation bar (LastGit compound) ---------------------------------
# Prove the candidate enforces /api/mutation `expected` on an ephemeral node
# (never live primary). RED blocks promotion: a CAS-disarmed node makes every
# LastGit ref write and terminal CI status write unconditional.
if [ "$CAS_SKIP" = "1" ]; then
  warn "CAS mutation bar SKIPPED (LASTDB_PROBE_CAS_SKIP=1) — Tom-clearance only; LastGit CAS will not be proven"
elif [ ! -x "$CAS_PROBE_SH" ] && [ ! -f "$CAS_PROBE_SH" ]; then
  warn "CAS mutation bar: probe script missing at $CAS_PROBE_SH — treating as SKIP (install last-stack skills)"
else
  log "CAS mutation bar: probing candidate $CANDIDATE_BIN on ephemeral throwaway node (not primary)"
  CAS_OUT="$WORK/cas-probe.out"
  set +e
  bash "$CAS_PROBE_SH" --lastdbd "$CANDIDATE_BIN" >"$CAS_OUT" 2>&1
  CAS_RC=$?
  set -e
  cat "$CAS_OUT"
  if [ "$CAS_RC" -ne 0 ] || grep -q 'VERDICT: RED' "$CAS_OUT"; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: candidate $CAND_VER failed the CAS mutation bar — promotion is blocked because the node accepted a false CAS precondition (or the probe could not prove enforcement)"
    echo "CANDIDATE: $CANDIDATE_BIN"
    echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
    echo "NEXT:   do NOT live-upgrade; fix /api/mutation expected-precondition enforcement before cutover (LastGit ref writes + terminal CI status rely on it). LASTDB_PROBE_CAS_SKIP=1 requires Tom clearance."
    exit 1
  fi
  if grep -q 'VERDICT: SKIP' "$CAS_OUT"; then
    warn "CAS mutation bar SKIPPED (tools/schema map / LastGit discriminator unavailable) — candidate not proven for LastGit CAS"
  else
    log "CAS mutation bar GREEN for candidate $CAND_VER"
  fi
fi

# RSS + like-to-like cold/hot latency. Clone both CoWs, boot both to
# identity-ready, cold fetch, settle + warmup, then hot medians.
# RSS incident 2026-07-22; latency 2026-07-25/27; mixed-thermal 2026-08-26.
log "RSS bar: limit=$(resolve_rss_limit_mb)MiB fail_at>=$(rss_fail_threshold_mb "$(resolve_rss_limit_mb)")MiB (headroom ${RSS_HEADROOM_PCT}%) settle=${RSS_SETTLE_SECS}s sample=${RSS_SAMPLE_SECS}s"
CAND_METRICS="$WORK/cand.metrics"
BASE_METRICS="$WORK/base.metrics"
BASELINE_BIN=""
if [ "$LAT_SKIP" != "1" ]; then
  BASELINE_BIN="$(resolve_baseline_bin)"
fi
log "latency: like-to-like cold+hot probe (candidate first identity, baseline sibling CoW)"
set +e
probe_like_to_like_metrics "$CANDIDATE_BIN" "$BASELINE_BIN" "$CAND_METRICS" "$BASE_METRICS"
CAND_METRICS_RC=$?
set -e
PROBE_RSS_MB="$(metric_val "$CAND_METRICS" peak_rss_mb)"
if [ "$CAND_METRICS_RC" -ne 0 ] || [ -z "$PROBE_RSS_MB" ]; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER failed the metrics probe (could not boot/serve a CoW copy for RSS + latency measurement)"
  echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
  echo "NEXT:   fix probe/CoW disk; do NOT live-upgrade until the RSS + latency bars are measurable"
  exit 1
fi
if ! enforce_rss_under_limit "$PROBE_RSS_MB" "probe"; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER peak_rss_mb=${PROBE_RSS_MB} exceeds memory-guard bar (limit=$(resolve_rss_limit_mb)MiB headroom=${RSS_HEADROOM_PCT}%)"
  echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
  echo "NEXT:   do NOT live-upgrade; raise LASTDBD_RSS_LIMIT_MB only with Tom clearance, or fix candidate memory before cutover"
  exit 1
fi
CAND_BOOT_SECS="$(metric_val "$CAND_METRICS" boot_secs)"
CAND_LAT_COLD_POINT_MS="$(metric_val "$CAND_METRICS" lat_cold_point_ms)"
CAND_LAT_COLD_SCAN_MS="$(metric_val "$CAND_METRICS" lat_cold_scan_ms)"
CAND_LAT_POINT_MS="$(metric_val "$CAND_METRICS" lat_hot_point_ms)"
CAND_LAT_SCAN_MS="$(metric_val "$CAND_METRICS" lat_hot_scan_ms)"
CAND_LAT_WRITE_MS="$(metric_val "$CAND_METRICS" lat_hot_write_ms)"
BASE_LAT_COLD_POINT_MS="$(metric_val "$BASE_METRICS" lat_cold_point_ms)"
BASE_LAT_COLD_SCAN_MS="$(metric_val "$BASE_METRICS" lat_cold_scan_ms)"
BASE_LAT_POINT_MS="$(metric_val "$BASE_METRICS" lat_hot_point_ms)"
BASE_LAT_SCAN_MS="$(metric_val "$BASE_METRICS" lat_hot_scan_ms)"
BASE_LAT_WRITE_MS="$(metric_val "$BASE_METRICS" lat_hot_write_ms)"
BASE_BOOT_SECS="$(metric_val "$BASE_METRICS" boot_secs)"
[ -n "$CAND_LAT_COLD_POINT_MS" ] || CAND_LAT_COLD_POINT_MS="-1"
[ -n "$CAND_LAT_COLD_SCAN_MS" ] || CAND_LAT_COLD_SCAN_MS="-1"
[ -n "$CAND_LAT_POINT_MS" ] || CAND_LAT_POINT_MS="-1"
[ -n "$CAND_LAT_SCAN_MS" ] || CAND_LAT_SCAN_MS="-1"
[ -n "$CAND_LAT_WRITE_MS" ] || CAND_LAT_WRITE_MS="-1"
[ -n "$BASE_LAT_COLD_POINT_MS" ] || BASE_LAT_COLD_POINT_MS="-1"
[ -n "$BASE_LAT_COLD_SCAN_MS" ] || BASE_LAT_COLD_SCAN_MS="-1"
[ -n "$BASE_LAT_POINT_MS" ] || BASE_LAT_POINT_MS="-1"
[ -n "$BASE_LAT_SCAN_MS" ] || BASE_LAT_SCAN_MS="-1"
[ -n "$BASE_LAT_WRITE_MS" ] || BASE_LAT_WRITE_MS="-1"

CAND_ROWS_POINT="$(metric_val "$CAND_METRICS" rows_point)"
CAND_ROWS_SCAN="$(metric_val "$CAND_METRICS" rows_scan)"
BASE_ROWS_POINT="$(metric_val "$BASE_METRICS" rows_point)"
BASE_ROWS_SCAN="$(metric_val "$BASE_METRICS" rows_scan)"
[ -n "$CAND_ROWS_POINT" ] || CAND_ROWS_POINT="-1"
[ -n "$CAND_ROWS_SCAN" ] || CAND_ROWS_SCAN="-1"
[ -n "$BASE_ROWS_POINT" ] || BASE_ROWS_POINT="-1"
[ -n "$BASE_ROWS_SCAN" ] || BASE_ROWS_SCAN="-1"

# Row-count bar. Deliberately NOT gated on LAT_SKIP: a candidate that answers
# every read with zero rows is wrong, not slow, and LASTDB_PROBE_LAT_SKIP must
# never buy a pass for it.
ROWS_RED=0
ROWS_RED_REASON=""
set +e
for rows_pair in "point-read:${CAND_ROWS_POINT}:${BASE_ROWS_POINT}" "kanban-scan:${CAND_ROWS_SCAN}:${BASE_ROWS_SCAN}"; do
  rows_label="${rows_pair%%:*}"
  rows_rest="${rows_pair#*:}"
  ROWS_OUT="$(rowcount_verdict "$rows_label" "${rows_rest%%:*}" "${rows_rest#*:}")"
  ROWS_RC=$?
  case "$ROWS_OUT" in
    *' RED:'*) log "$ROWS_OUT" ;;
    *' WARN:'*|*'SKIPPED'*) warn "$ROWS_OUT" ;;
    *) log "$ROWS_OUT" ;;
  esac
  if [ "$ROWS_RC" -ne 0 ]; then
    ROWS_RED=1
    ROWS_RED_REASON="${rows_label} returned 0 rows on the candidate while the baseline returned rows on the same CoW data"
  fi
done
set -e
if [ "$ROWS_RED" -ne 0 ]; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: candidate $CAND_VER fails the row-count bar (${ROWS_RED_REASON}) — a read that answers FAST with ZERO rows is not GREEN (incident 2026-09-03: lastdbd 0.23.3-1535 served every kanban BoardCards read empty, ship rate went to 0, and every latency bar passed because an empty answer is the fastest answer)"
  echo "ROWCOUNT: point cand=${CAND_ROWS_POINT}(base ${BASE_ROWS_POINT}) scan cand=${CAND_ROWS_SCAN}(base ${BASE_ROWS_SCAN})"
  echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
  echo "NEXT:   do NOT live-upgrade; the candidate's hash-key/range read path is broken for at least one real schema. Brain: papercut-lastdb-1535-hashrange-board-queries-return-zero-rows-after-cutover-20260903. There is no skip flag for this bar."
  exit 1
fi


if [ "$LAT_SKIP" != "1" ]; then
  if [ -n "$BASE_BOOT_SECS" ] && [ -n "$CAND_BOOT_SECS" ] \
    && [ "$CAND_BOOT_SECS" -gt $((BASE_BOOT_SECS * 3)) ] 2>/dev/null \
    && [ "$CAND_BOOT_SECS" -gt $((BASE_BOOT_SECS + 60)) ] 2>/dev/null; then
    warn "candidate boot ${CAND_BOOT_SECS}s vs baseline ${BASE_BOOT_SECS}s — possible one-time migration; expect a longer live cutover window (not RED by itself)"
  fi

  LAT_RED=0
  LAT_RED_REASON=""
  # like-to-like cold/hot per-op + lat_correlated_within_bar on the HOT triple
  export LASTDB_PROBE_LAT_FLOOR_MS="${LAT_FLOOR_MS}"
  export LASTDB_PROBE_LAT_RATIO="${LAT_RATIO}"
  export LASTDB_PROBE_LAT_ABS_MAX_MS="${LAT_ABS_MAX_MS}"
  set +e
  LIKE_OUT="$(lat_apply_like_to_like_bars \
    "$CAND_LAT_COLD_POINT_MS" "$BASE_LAT_COLD_POINT_MS" \
    "$CAND_LAT_COLD_SCAN_MS" "$BASE_LAT_COLD_SCAN_MS" \
    "$CAND_LAT_POINT_MS" "$BASE_LAT_POINT_MS" \
    "$CAND_LAT_SCAN_MS" "$BASE_LAT_SCAN_MS" \
    "$CAND_LAT_WRITE_MS" "$BASE_LAT_WRITE_MS")"
  LIKE_RC=$?
  set -e
  if [ -n "$LIKE_OUT" ]; then
    while IFS= read -r like_line || [ -n "$like_line" ]; do
      [ -n "$like_line" ] || continue
      case "$like_line" in
        *' RED:'*) log "$like_line"; LAT_RED=1 ;;
        *'SKIPPED'*) warn "$like_line" ;;
        *'mixed thermal'*) log "$like_line" ;;
        *) log "$like_line" ;;
      esac
    done <<EOF
$LIKE_OUT
EOF
  fi
  if [ "$LIKE_RC" -ne 0 ]; then
    LAT_RED=1
    LAT_RED_REASON="like-to-like cold/hot bar (per-op ${LAT_RATIO}x and/or hot geo-mean)"
  fi
  if [ "$LAT_RED" -ne 0 ]; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: candidate $CAND_VER fails the latency bar (${LAT_RED_REASON:-unknown}) — correct-but-slow is NOT GREEN (incident 2026-07-25/27 single-op; 2026-08-05 correlated moderate regression; 2026-08-26 mixed-thermal)"
    echo "LATENCY: cold_point=${CAND_LAT_COLD_POINT_MS}ms(base ${BASE_LAT_COLD_POINT_MS}ms) cold_scan=${CAND_LAT_COLD_SCAN_MS}ms(base ${BASE_LAT_COLD_SCAN_MS}ms) hot_point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) hot_scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) hot_write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) ratio-bar=${LAT_RATIO}x floor=${LAT_FLOOR_MS}ms abs-max=${LAT_ABS_MAX_MS}ms corr-ratio=${LASTDB_PROBE_LAT_CORR_RATIO}x geo-mean-max=${LASTDB_PROBE_LAT_GEO_MEAN_MAX}x"
    echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
    echo "NEXT:   do NOT live-upgrade; profile the candidate's read/write paths (brain: lastdb-0231-hashgroup-scan-warmset-thrash-read-regression, papercut-safe-upgrade-point-read-bar-cold-first-boot-vs-subfloor-baseline). Re-running with LASTDB_PROBE_LAT_SKIP=1 or LASTDB_PROBE_LAT_CORR_SKIP=1 requires Tom's explicit clearance."
    exit 1
  fi
else
  warn "latency bar SKIPPED (LASTDB_PROBE_LAT_SKIP=1) — Tom-clearance only; correct-but-slow will NOT be caught"
fi
log "row-count bar GREEN: point cand=${CAND_ROWS_POINT}(base ${BASE_ROWS_POINT}) scan cand=${CAND_ROWS_SCAN}(base ${BASE_ROWS_SCAN})"
log "probe GREEN for candidate $CAND_VER (data-plane + RSS peak_mb=${PROBE_RSS_MB} + cold_point/scan=${CAND_LAT_COLD_POINT_MS}/${CAND_LAT_COLD_SCAN_MS}ms hot_point/scan/write=${CAND_LAT_POINT_MS}/${CAND_LAT_SCAN_MS}/${CAND_LAT_WRITE_MS}ms)"

if [ "$PROBE_ONLY" -eq 1 ]; then
  release_rollback_point
  echo ""
  echo "VERDICT: GREEN_PROBE_ONLY"
  echo "SUMMARY: candidate $CAND_VER boots and serves a CoW of real data; peak_rss_mb=${PROBE_RSS_MB} under guard limit=$(resolve_rss_limit_mb); latency within bar. Primary left on $CURRENT_VER."
  echo "ROLLBACK: released (probe GREEN; primary untouched)"
  echo "RSS:     peak_mb=${PROBE_RSS_MB} limit_mb=$(resolve_rss_limit_mb) fail_at_mb=$(rss_fail_threshold_mb "$(resolve_rss_limit_mb)")"
  echo "LATENCY: cold_point=${CAND_LAT_COLD_POINT_MS}ms(base ${BASE_LAT_COLD_POINT_MS}ms) cold_scan=${CAND_LAT_COLD_SCAN_MS}ms(base ${BASE_LAT_COLD_SCAN_MS}ms) hot_point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) hot_scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) hot_write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) boot=${CAND_BOOT_SECS}s(base ${BASE_BOOT_SECS:-?}s)"
  echo "ROWCOUNT: point cand=${CAND_ROWS_POINT}(base ${BASE_ROWS_POINT}) scan cand=${CAND_ROWS_SCAN}(base ${BASE_ROWS_SCAN})"
  echo "NEXT:    run last-stack-safe-upgrade-loom --candidate $CANDIDATE_BIN --source-git-oid <full-fold-commit>"
  exit 0
fi

# --- 2b) DEV photograph stamp gate (Tom 2026-08-19) --------------------------
# Live cutover is refused unless an ephemeral/CoW copy already uploaded a
# photograph to DEV and CAS-flipped backup/latest. LASTDB_PROBE_DEV_STAMP_SKIP=1
# is Tom clearance only.
if [ "${LASTDB_PROBE_DEV_STAMP_SKIP:-0}" = "1" ]; then
  warn "DEV photograph stamp SKIPPED (LASTDB_PROBE_DEV_STAMP_SKIP=1) — Tom-clearance only; live cutover will not prove backup-to-DEV"
else
  DEV_STAMP_OUT=""
  set +e
  DEV_STAMP_OUT="$(assert_dev_photograph_stamp_ok "$(dev_stamp_receipt_path)" "$PRIMARY_HOME" 2>&1)"
  DEV_STAMP_RC=$?
  set -e
  if [ -n "$DEV_STAMP_OUT" ]; then
    while IFS= read -r line; do
      case "$line" in
        WARN:*) warn "${line#WARN: }" ;;
        RED:*)  log "DEV photograph stamp $line" ;;
        *)      log "DEV photograph stamp: $line" ;;
      esac
    done <<< "$DEV_STAMP_OUT"
  fi
  if [ "$DEV_STAMP_RC" -ne 0 ]; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: live cutover refused — DEV photograph stamp is missing or RED. Boot the candidate on an ephemeral/CoW copy of real data, upload the photograph to DEV (not the primary production backup home), and record a GREEN stamp. Never point the candidate at live ~/.lastdb."
    echo "RECEIPT: $(dev_stamp_receipt_path)"
    echo "NEXT:    run the DEV photograph stamp (lastdb connect --env dev on the CoW, then lastdb cloud snapshot) then re-run this driver."
    exit 1
  fi
  log "DEV photograph stamp GREEN ($(dev_stamp_receipt_path))"
fi

# --- 3) human confirm before touching live -----------------------------------

detect_live_venue

if [ "$ASSUME_YES" -eq 0 ]; then
  if [ ! -t 0 ]; then
    die "refusing live upgrade without --yes in non-interactive mode (probe was GREEN; pass --yes to proceed)"
  fi
  echo ""
  echo "Probe GREEN. About to perform LIVE cutover (venue=$VENUE):"
  if [ "$VENUE" = "sidebin" ]; then
    echo "  atomic install → $SIDEBIN_DIR/lastdbd"
    echo "  launchctl bootout + bootstrap reload of $LAUNCHD_PLIST"
  else
    echo "  brew upgrade edgevector/lastdb/lastdb"
    echo "  brew services restart lastdb"
  fi
  echo "  post-check live /health + Board title"
  echo "Ephemeral rollback point: $BACKUP (released if the operator aborts)"
  printf "Proceed with LIVE upgrade? [y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) release_rollback_point; log "aborted by user; primary still on $CURRENT_VER; rollback point released"; exit 0 ;;
  esac
fi

# --- 4) live upgrade (venue-aware) -------------------------------------------

log "STEP 3/4: live install + supervisor restart (venue=$VENUE)"

# Arm the durability canary before any live change and before the cutover
# clock starts, so cutover_s stays comparable to historical runs.
durability_write_sentinels

CUTOVER_T0="$(date +%s)"

assert_launchd_label_usable

# The daemon consumes this marker only after it durably appends the next boot
# row. Cleanup removes it when this script aborts before a successful start
# request. A successful start leaves it for the new daemon.
write_upgrade_restart_intent

if [ "$VENUE" = "sidebin" ]; then
  live_install_sidebin
  INSTALLED_DAEMON_BIN="$SIDEBIN_DIR/lastdbd"
  INSTALLED="$("$SIDEBIN_DIR/lastdbd" --version 2>/dev/null | awk '{print $NF}' || true)"
  INSTALLED_CLI_BIN="$SIDEBIN_DIR/lastdb"
else
  live_install_brew
  INSTALLED_DAEMON_BIN="$(command -v lastdbd 2>/dev/null || true)"
  INSTALLED="$(lastdbd --version 2>/dev/null | awk '{print $NF}' || true)"
  INSTALLED_CLI_BIN="$(command -v lastdb 2>/dev/null || true)"
fi

log "installed lastdbd --version: $INSTALLED"
[ -n "$INSTALLED" ] || die "could not read installed lastdbd --version"
[ "$INSTALLED" = "$CAND_VER" ] || die "installed lastdbd version ($INSTALLED) != candidate ($CAND_VER)"
INSTALLED_PAIR_OUT=""
set +e
INSTALLED_PAIR_OUT="$(assert_lastdb_binary_pair_ok "$INSTALLED_DAEMON_BIN" "$INSTALLED_CLI_BIN" "$CAND_VER" "installed live pair" 2>&1)"
INSTALLED_PAIR_RC=$?
set -e
if [ -n "$INSTALLED_PAIR_OUT" ]; then
  while IFS= read -r line; do
    case "$line" in
      RED:*) log "binary pair $line" ;;
      *)     log "binary pair: $line" ;;
    esac
  done <<< "$INSTALLED_PAIR_OUT"
fi
[ "$INSTALLED_PAIR_RC" -eq 0 ] || die "installed lastdb/lastdbd version parity check failed"
INSTALLED_CLI="$(lastdb_binary_version "$INSTALLED_CLI_BIN" || true)"
log "installed lastdb --version: $INSTALLED_CLI"

# Wait for live socket health. A leftover inode without a listener is not
# healthy — require pid + /health, same bar as live_install_sidebin.
LIVE_OK=0
for i in $(seq 1 120); do
  if live_unix_socket_is_healthy "$PRIMARY_SOCK"; then
    LIVE_OK=1
    break
  fi
  sleep 1
done
[ "$LIVE_OK" -eq 1 ] || die "live /health not ok after cutover — STOP. Binary rollback: restore $SIDEBIN_DIR/lastdbd.bak-pre-* if sidebin; data backup: $BACKUP"

# THE cutover assertion: the RUNNING daemon must report the candidate version.
#
# Everything else in this post-check (health, identity, schemas, Board title,
# RSS, latency) passes perfectly against the OLD daemon — it is healthy, it is
# serving, it is simply the wrong binary. Installing the file is not the
# cutover; replacing the process is. Assert the claim, not a proxy for it.
#
# Incident 2026-08-07: printed "VERDICT: GREEN ... cutover_s=303" while pid and
# uptime were unchanged and /api/status still reported the old build. Brain:
# papercut-safe-upgrade-reports-green-cutover-without-restarting-primary
#
# The READ is polled; the MISMATCH is not. These are different claims and the
# single 15s one-shot this replaces collapsed them:
#
#   * "the status route has not answered yet" is no evidence at all about which
#     binary is running. /health answering ok does NOT mean /api/status can be
#     served — it walks far more of the node. Measured on Tom's primary across
#     two real cutovers on 2026-08-09: at a 65 GiB store the first post-restart
#     /api/status took 22.3s, and at 92 GiB it took over 90s (the same call
#     returned in 20ms two minutes later). Both were healthy cutovers onto the
#     correct binary and both were reported RED, whose documented response is
#     "stop and restore" — so the guard was one compliant operator away from
#     rolling a good binary off the primary and restarting it a second time to
#     do it. The window widens as the store grows.
#   * a version that IS returned and is the OLD one is the 2026-08-07 incident,
#     it is provable on the first successful read, and waiting cannot change it.
#     That branch stays immediate, below.
#
# Brain: papercut-safe-upgrade-postcheck-red-on-a-successful-cutover-because-the-version-read-does-not-retry
VERSION_WAIT_S="${LASTDB_POSTCHECK_VERSION_WAIT_S:-300}"
VERSION_WAIT_START="$(date +%s)"
VERSION_DEADLINE=$(( VERSION_WAIT_START + VERSION_WAIT_S ))
VERSION_POLLS=0
RUNNING_VERSION=""
while :; do
  RUNNING_VERSION="$(curl -sS --max-time 15 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
    http://x/api/status 2>/dev/null | jq -r '.status.build.version // empty' || true)"
  VERSION_POLLS=$(( VERSION_POLLS + 1 ))
  [ -n "$RUNNING_VERSION" ] && break
  [ "$(date +%s)" -ge "$VERSION_DEADLINE" ] && break
  # Say it out loud rather than looking hung: this can legitimately take minutes.
  if [ "$(( VERSION_POLLS % 4 ))" -eq 1 ]; then
    log "post-check: /api/status has not reported build.version yet after $(( $(date +%s) - VERSION_WAIT_START ))s (node still warming); waiting up to ${VERSION_WAIT_S}s"
  fi
  sleep 5
done
VERSION_WAIT_ELAPSED=$(( $(date +%s) - VERSION_WAIT_START ))
if [ -z "$RUNNING_VERSION" ]; then
  die "live /api/status did not report build.version within ${VERSION_WAIT_S}s (${VERSION_POLLS} polls) after cutover — cannot prove the primary restarted onto $INSTALLED; treat as RED"
fi
if [ "$VERSION_WAIT_ELAPSED" -ge 15 ]; then
  log "post-check: /api/status reported build.version after ${VERSION_WAIT_ELAPSED}s (${VERSION_POLLS} polls) — a one-shot read would have failed this cutover"
fi
if [ -n "${INSTALLED:-}" ] && [ "$RUNNING_VERSION" != "$INSTALLED" ]; then
  echo ""
  echo "VERDICT: RED"
  echo "REASON: primary did NOT restart onto the candidate — running=$RUNNING_VERSION installed=$INSTALLED"
  echo "        The binary is installed but the process was never replaced."
  echo "        Most likely the launchd label is wrong, so kickstart was a no-op."
  echo "        Resolved label: $LAUNCHD_LABEL (venue=$VENUE)"
  echo "        Check: launchctl list | grep lastdbd"
  echo "BACKUP: $BACKUP"
  die "cutover did not take effect; primary still running $RUNNING_VERSION"
fi
log "cutover verified: running daemon reports $RUNNING_VERSION (matches installed candidate)"

# The file on disk and launchd's cached job definition are separate state.
# Prove every configured EnvironmentVariables key exists in the new process;
# report key names only so no secret or tuning value reaches logs.
LIVE_PID="$(resolve_live_primary_pid)"
if [ "$VENUE" = "sidebin" ]; then
  if [ -z "$LIVE_PID" ]; then
    if [ "$LIVE_CONFIG_ENFORCE" = "1" ]; then
      die "live config drift check could not resolve the primary pid"
    fi
    warn "LIVE_CONFIG_DRIFT=unmeasured reason=primary-pid-unresolved (LASTDB_LIVE_CONFIG_ENFORCE=1 makes this RED)"
  elif ! lastdb_live_config_drift_check "$LAUNCHD_PLIST" "$LIVE_PID"; then
    die "live process is missing LaunchAgent EnvironmentVariables keys (LASTDB_LIVE_CONFIG_ENFORCE=1)"
  fi
fi

# Live data plane spot-check (same bar as smoke: Board titles rehydrate)
UH="$(curl -sS --max-time 5 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/system/auto-identity 2>/dev/null | jq -r '.user_hash // empty')"
[ -n "$UH" ] || die "live auto-identity empty after cutover — treat as RED; consider restore from $BACKUP"
NSCHEMAS="$(curl -sS --max-time 30 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/schemas 2>/dev/null | jq -r '.schemas|length // 0')"
[ "${NSCHEMAS:-0}" -gt 0 ] || die "live /api/schemas empty after cutover — treat as RED; restore from $BACKUP"
QRES="$(curl -sS --max-time 30 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' -H 'Content-Type: application/json' \
  --data '{"schema_name":"Board","fields":["title"],"filter":{"HashKey":"default"}}' http://x/api/query 2>/dev/null || true)"
QOK="$(echo "$QRES" | jq -r '.ok // empty' 2>/dev/null || true)"
QVAL="$(echo "$QRES" | jq -r '.results[0].fields.title // .results[0].title // empty' 2>/dev/null || true)"
[ "$QOK" = "true" ] && [ -n "$QVAL" ] || die "live Board query failed after cutover — treat as RED; restore from $BACKUP"

# Attribution aid for a durability RED: say whether the old daemon drained
# cleanly. Warn-only — the canary below is the authority, not this string.
DRAIN_LINE="$(run_op_with_deadline 15 "$INSTALLED_CLI_BIN" status 2>/dev/null | grep -i 'did not complete its clean drain' || true)"
[ -n "$DRAIN_LINE" ] && warn "previous daemon session did not complete its clean drain — if the durability canary goes RED, this restart is the prime suspect"

# Durability canary read-back: every sentinel the OLD daemon acked must read
# back with THIS run's nonce on the NEW daemon.
durability_verify_after_cutover

# Live RSS vs memory-guard (settle briefly — embeddings may still be loading).
log "live RSS settle ${RSS_SETTLE_SECS}s then sample ${RSS_SAMPLE_SECS}s..."
sleep "$RSS_SETTLE_SECS"
if [ -z "${LIVE_PID:-}" ]; then
  LIVE_PID="$(resolve_live_primary_pid)"
fi
LIVE_RSS_MB=0
if [ -n "${LIVE_PID:-}" ]; then
  for i in $(seq 1 "$RSS_SAMPLE_SECS"); do
    r="$(rss_mb_of_pid "$LIVE_PID")"
    if [ "$r" -gt "$LIVE_RSS_MB" ] 2>/dev/null; then LIVE_RSS_MB="$r"; fi
    sleep 1
  done
else
  warn "live RSS: could not resolve primary pid; skipping hard fail (data-plane ok)"
  LIVE_RSS_MB=""
fi
if [ -n "${LIVE_RSS_MB:-}" ]; then
  if ! enforce_rss_under_limit "$LIVE_RSS_MB" "live"; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: live peak_rss_mb=${LIVE_RSS_MB} exceeds memory-guard bar after cutover — primary may thrash-restart"
    echo "BACKUP: $BACKUP"
    echo "BINARY ROLLBACK (preferred first try, sidebin):"
    echo "  cp -a $SIDEBIN_DIR/lastdbd.bak-pre-* $SIDEBIN_DIR/lastdbd  # pick newest bak"
    echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
    die "live RSS over memory-guard bar; restore binary bak if thrashing continues"
  fi
fi

# Live latency spot-check: point-read AND kanban list scan (incident 2026-08-01:
# live point stayed ~113ms while list went multi-second→60s; point-only missed
# it). Compared against the candidate's OWN probe numbers (same binary).
# Defaults to WARN under client load; LASTDB_LIVE_LAT_ENFORCE=1 → RED.
LIVE_LAT_POINT_MS="-1"
LIVE_LAT_SCAN_MS="-1"
live_lat_check_op() {
  # $1=label $2=live_ms $3=cand_probe_ms
  local label="$1" live_ms="$2" cand_ms="$3"
  if [ "$live_ms" = "-1" ] || [ -z "$live_ms" ]; then
    warn "live $label latency: unmeasured"
    return 0
  fi
  if [ "${cand_ms:--1}" = "-1" ] || [ -z "$cand_ms" ]; then
    log "live $label latency: ${live_ms}ms (no candidate probe number to compare)"
    return 0
  fi
  if [ "$live_ms" -gt "$LAT_FLOOR_MS" ] 2>/dev/null \
    && awk -v c="$live_ms" -v b="$cand_ms" -v r="$LAT_RATIO" 'BEGIN{exit !(c > b*r)}'; then
    if [ "$LIVE_LAT_ENFORCE" = "1" ]; then
      echo ""
      echo "VERDICT: RED"
      echo "REASON: live $label ${live_ms}ms is >${LAT_RATIO}x the candidate's probe ${cand_ms}ms after cutover"
      echo "BACKUP: $BACKUP"
      echo "BINARY ROLLBACK (preferred first try, sidebin):"
      echo "  cp -a $SIDEBIN_DIR/lastdbd.bak-pre-* $SIDEBIN_DIR/lastdbd  # pick newest bak"
      echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
      die "live $label latency far above the candidate's own probe numbers"
    fi
    warn "live $label ${live_ms}ms is >${LAT_RATIO}x the candidate's probe ${cand_ms}ms — may be client load; WATCH the primary (LASTDB_LIVE_LAT_ENFORCE=1 makes this RED)"
  else
    log "live $label latency: ${live_ms}ms (candidate probe: ${cand_ms}ms)"
  fi
}
if [ "$LAT_SKIP" != "1" ]; then
  LIVE_LAT_POINT_MS="$(measure_op_median_ms op_lat_point "$PRIMARY_SOCK" "live point-read")"
  live_lat_check_op "point-read" "$LIVE_LAT_POINT_MS" "${CAND_LAT_POINT_MS:--1}"
  if command -v kanban >/dev/null 2>&1; then
    LIVE_LAT_SCAN_MS="$(measure_op_median_ms op_lat_scan "$PRIMARY_HOME" "live kanban-scan")"
    live_lat_check_op "scan (kanban list)" "$LIVE_LAT_SCAN_MS" "${CAND_LAT_SCAN_MS:--1}"
  else
    warn "live scan latency: kanban CLI not on PATH — unmeasured"
  fi
fi

# A leftover listener + nohup --data-dir start can look healthy and still leave
# the LaunchAgent unloaded (PPID=1). That is not GREEN. LIVE_CONFIG_DRIFT above
# still names missing plist env keys. Bootstrap the job, or stay RED.
if [ "$VENUE" = "sidebin" ]; then
  _uid="$(id -u)"
  _svc="gui/${_uid}/${LAUNCHD_LABEL}"
  if [ -z "${LIVE_PID:-}" ]; then
    LIVE_PID="$(resolve_live_primary_pid)"
  fi
  set +e
  SUPERVISED_OUT="$(lastdb_require_supervised_primary launchctl "$_svc" "${LIVE_PID:-}" 2>&1)"
  SUPERVISED_RC=$?
  set -e
  if [ -n "$SUPERVISED_OUT" ]; then
    if [ "$SUPERVISED_RC" -eq 0 ]; then
      log "$SUPERVISED_OUT"
    else
      warn "$SUPERVISED_OUT"
    fi
  fi
  if [ "$SUPERVISED_RC" -ne 0 ]; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: primary LaunchAgent is unloaded or is not the live pid — a nohup --data-dir start is not GREEN"
    echo "        service=$_svc live_pid=${LIVE_PID:-unset}"
    echo "        Recover: launchctl bootstrap gui/${_uid} ${LAUNCHD_PLIST}"
    echo "        Then: launchctl print $_svc  # must show state=running and this pid"
    echo "BACKUP: $BACKUP"
    die "primary LaunchAgent is not supervising the live daemon; KeepAlive does not own lastdbd"
  fi
fi

CUTOVER_T1="$(date +%s)"
CUTOVER_SECS=$((CUTOVER_T1 - CUTOVER_T0))
log "STEP 4/4: live post-check GREEN (schemas=$NSCHEMAS first Board title=\"$QVAL\" cutover_s=$CUTOVER_SECS venue=$VENUE peak_rss_mb=${LIVE_RSS_MB:-unknown} live_point_ms=${LIVE_LAT_POINT_MS:-unmeasured} live_scan_ms=${LIVE_LAT_SCAN_MS:-unmeasured} durability=${DURABILITY_N}/${DURABILITY_N})"

# Post a Situations notice so other agents attribute post-upgrade flapping.
POST_NOTICE=""
for cand in \
  "${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-post-notice" \
  "$HOME/code/edgevector/last-stack/bin/last-stack-post-notice"
do
  [ -x "$cand" ] && POST_NOTICE="$cand" && break
done
NOTICE_SUMMARY="lastdbd ${CURRENT_VER} → ${INSTALLED} with lastdb=${INSTALLED_CLI:-?} venue=${VENUE} cutover_s=${CUTOVER_SECS}; probe latency point/scan/write=${CAND_LAT_POINT_MS:-?}/${CAND_LAT_SCAN_MS:-?}/${CAND_LAT_WRITE_MS:-?}ms (baseline ${BASE_LAT_POINT_MS:-?}/${BASE_LAT_SCAN_MS:-?}/${BASE_LAT_WRITE_MS:-?}ms) live_point_ms=${LIVE_LAT_POINT_MS:-?} live_scan_ms=${LIVE_LAT_SCAN_MS:-?} durability=${DURABILITY_N}/${DURABILITY_N} durability_mode=${DURABILITY_MODE:-durable}; brief socket blips expected. Do not open a new incident or restart the primary for flapping alone. Design: lastdb-minimal-downtime-cutover."
if [ -n "$POST_NOTICE" ]; then
  if "$POST_NOTICE" \
    --title "LastDB upgraded to ${INSTALLED}" \
    --kind upgrade \
    --system lastdbd \
    --system primary-brain \
    --app brain \
    --app kanban \
    --app situations \
    --actor skill:lastdb-safe-upgrade \
    --summary "$NOTICE_SUMMARY" \
    --expires-hours 12 \
    >/dev/null 2>&1; then
    log "posted situations notice for upgrade ${CURRENT_VER} → ${INSTALLED}"
  else
    warn "could not post situations notice via last-stack-post-notice; upgrade still GREEN"
  fi
elif command -v situations >/dev/null 2>&1; then
  if situations notice \
    --title "LastDB upgraded to ${INSTALLED}" \
    --kind upgrade \
    --system lastdbd \
    --system primary-brain \
    --app brain \
    --app kanban \
    --app situations \
    --actor skill:lastdb-safe-upgrade \
    --summary "$NOTICE_SUMMARY" \
    --expires-hours 12 \
    2>/dev/null; then
    log "posted situations notice for upgrade ${CURRENT_VER} → ${INSTALLED}"
  else
    warn "could not post situations notice; upgrade still GREEN"
  fi
else
  warn "situations CLI not on PATH — skipped agent-impact notice for this upgrade"
fi

# GREEN is terminal: the rollback point has served its purpose and must not
# become a backup under another name.
release_rollback_point

echo ""
echo "VERDICT: GREEN"
echo "SUMMARY: upgraded lastdbd $CURRENT_VER → $INSTALLED and lastdb → ${INSTALLED_CLI:-?}; venue=$VENUE; cutover_s=$CUTOVER_SECS; probe + live Board read OK; probe_rss_mb=${PROBE_RSS_MB:-?} live_rss_mb=${LIVE_RSS_MB:-?} limit_mb=$(resolve_rss_limit_mb); rollback point released"
echo "LATENCY: probe point/scan/write=${CAND_LAT_POINT_MS:-?}/${CAND_LAT_SCAN_MS:-?}/${CAND_LAT_WRITE_MS:-?}ms baseline=${BASE_LAT_POINT_MS:-?}/${BASE_LAT_SCAN_MS:-?}/${BASE_LAT_WRITE_MS:-?}ms live_point=${LIVE_LAT_POINT_MS:-?}ms live_scan=${LIVE_LAT_SCAN_MS:-?}ms"
echo ""
echo "ROLLBACK (binary only, if new binary misbehaves but data is fine):"
if [ "$VENUE" = "sidebin" ]; then
  echo "  cp -a $SIDEBIN_DIR/lastdbd.bak-pre-${CAND_VER}-* $SIDEBIN_DIR/lastdbd   # pick newest bak"
  echo "  cp -a $SIDEBIN_DIR/lastdb.bak-pre-${CAND_VER}-* $SIDEBIN_DIR/lastdb     # pick matching newest bak"
  echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
else
  echo "  brew services stop lastdb"
  echo "  brew reinstall edgevector/lastdb/lastdb  # or prior bottle"
  echo "  brew services start lastdb"
fi
echo ""
echo "DATA ROLLBACK: not retained after GREEN. Any RED or driver-ended step keeps the newest"
echo "ephemeral CoW rollback point for ${ROLLBACK_TTL_HOURS}h; the next safe-upgrade run reuses it."
exit 0
