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
#   safe-upgrade-lastdb.sh                  # resolve → probe → live if green
#   safe-upgrade-lastdb.sh --probe-only     # rollback point + probe only (no live install)
#   safe-upgrade-lastdb.sh --yes            # no confirm prompt before live cutover
#   safe-upgrade-lastdb.sh --candidate /path/to/lastdbd
#   safe-upgrade-lastdb.sh --version 0.22.8 # fetch that tap release tarball
#   safe-upgrade-lastdb.sh --check-dev-stamp  # refuse/allow live based on DEV photograph receipt only
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
ROLLBACK_ROOT="${LASTDB_ROLLBACK_ROOT:-${LASTDB_BACKUP_ROOT:-${TMPDIR:-/tmp}/lastdb-safe-upgrade-rollback-${UID:-$(id -u)}}}"
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

cleanup_work() {
  local rc=$?
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  if [ "${ROLLBACK_READY:-0}" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      release_rollback_point
    else
      retain_rollback_point
    fi
  fi
}
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

prepare_rollback_root() {
  local root_real home_real d base reclaimed=0
  mkdir -p "$ROLLBACK_ROOT"
  [ ! -L "$ROLLBACK_ROOT" ] || die "rollback root must not be a symlink: $ROLLBACK_ROOT"
  root_real="$(cd "$ROLLBACK_ROOT" && pwd -P)"
  home_real="$(cd "$HOME" && pwd -P)"
  case "$root_real" in
    "$home_real"|"$home_real"/*)
      die "rollback root must be ephemeral and outside HOME: $root_real"
      ;;
  esac
  for d in "$ROLLBACK_ROOT"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    base="$(basename "$d")"
    is_routine_pre_upgrade_backup "$base" || continue
    log "rollback: reclaim previous retained point $d"
    rm -rf "$d"
    reclaimed=$((reclaimed + 1))
  done
  log "rollback: root=$root_real previous_reclaimed=$reclaimed ttl_hours=$ROLLBACK_TTL_HOURS cleanup_owner=next-lastdb-safe-upgrade-run"
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

run_op_with_deadline() {
  # $1 = seconds; rest = command. Returns 124 if the deadline killed it.
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  [ "$rc" -eq 137 ] && return 124
  return "$rc"
}

# Latency ops. Each takes one arg and must exit non-zero on failure. These are
# the REAL workloads: the keyed point read from the smoke bar, the scan-shaped
# read that regressed in 0.23.1 (kanban list), and a real brain upsert (writes
# only ever land on the throwaway CoW copy, never the primary).
op_lat_point() {
  # $1 = socket path
  curl -sS --max-time "$LAT_OP_TIMEOUT_SECS" --unix-socket "$1" -H 'Host: localhost' \
    -H 'Content-Type: application/json' \
    --data '{"schema_name":"Board","fields":["title"],"filter":{"HashKey":"default"}}' \
    http://x/api/query 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
}

op_lat_scan() {
  # $1 = probe copy home
  env FOLDDB_SOCKET_PATH="$1/data/folddb.sock" LASTDB_HOME="$1" FOLDDB_HOME="$1" \
    kanban list --column todo --json >/dev/null 2>&1
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
# through the ordinary app write path (brain put), each carrying a run-unique
# nonce, and read each back. After the cutover, read them again on the new
# daemon. A sentinel whose body carries the PREVIOUS run's nonce is exactly
# the observed loss shape (last write to a key dropped, prior version
# survives). Fixed slugs keep the store flat; N spreads sentinels across hash
# groups because the loss was per-key, not per-interval. There is deliberately
# no skip flag — a durability bar that can be skipped recurs silently.
# ---------------------------------------------------------------------------
DURABILITY_N="${LASTDB_DURABILITY_CANARY_N:-4}"
DURABILITY_READ_WAIT_S="${LASTDB_DURABILITY_READ_WAIT_S:-120}"
DURABILITY_SLUG_PREFIX="lastdb-safe-upgrade-durability-canary"
DURABILITY_NONCE=""

durability_slug() { printf '%s-%d' "$DURABILITY_SLUG_PREFIX" "$1"; }

durability_read_body() {
  # $1 = slug. stdout: the record as brain prints it (empty on any failure).
  run_op_with_deadline 15 env FBRAIN_FOLDDB_SOCKET="$PRIMARY_SOCK" \
    LASTDB_HOME="$PRIMARY_HOME" FOLDDB_HOME="$PRIMARY_HOME" \
    brain get "$1" 2>/dev/null || true
}

durability_write_sentinels() {
  # Runs BEFORE any live change; a failure here aborts a not-yet-started
  # cutover, which is the honest outcome — an upgrade whose durability bar
  # cannot arm must not proceed to the restart that bar exists to judge.
  DURABILITY_NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local i slug
  for i in $(seq 1 "$DURABILITY_N"); do
    slug="$(durability_slug "$i")"
    printf -- '---\ntype: reference\nslug: %s\ntitle: safe-upgrade durability canary %d (constant slug; nonce changes per run)\n---\nnonce: %s#%d\n\nWritten by lastdb-safe-upgrade immediately before the cutover restart and\nread back after it. A stale nonce after an upgrade means the primary lost an\nacknowledged write across the restart. Safe to keep; carries no other\nmeaning. Rationale: brain\npapercut-lastdb-acked-write-lost-loom-terminal-status-regressed.\n' \
      "$slug" "$i" "$DURABILITY_NONCE" "$i" \
      | env FBRAIN_FOLDDB_SOCKET="$PRIMARY_SOCK" LASTDB_HOME="$PRIMARY_HOME" FOLDDB_HOME="$PRIMARY_HOME" \
        brain put >/dev/null 2>&1 \
      || die "durability canary: pre-cutover write of $slug failed — aborting before any live change (the canary must arm to prove the cutover keeps acked writes)"
    durability_read_body "$slug" | grep -qF "nonce: ${DURABILITY_NONCE}#${i}" \
      || die "durability canary: pre-cutover read-back of $slug did not return this run's nonce — primary already unhealthy; aborting before any live change"
  done
  log "durability canary: armed — $DURABILITY_N sentinels written and read back on the old daemon (nonce $DURABILITY_NONCE)"
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
  # $1 = op label, $2 = candidate ms, $3 = baseline ms (-1 = unmeasured).
  # rc 0 = within bar; rc 1 = RED.
  # With a baseline, the RATIO governs: the bar exists to catch regressions the
  # CANDIDATE introduces. Pre-existing slowness (baseline equally over the
  # ceiling) is loudly WARNed, not RED — a bar that REDs on the status quo just
  # trains everyone to skip it. Without a baseline the ceiling is the only
  # protection, so there it is RED.
  local op="$1" cand="$2" base="$3"
  if [ "$cand" = "-1" ] || [ -z "$cand" ]; then
    if [ -n "$base" ] && [ "$base" != "-1" ]; then
      log "latency $op RED: unmeasurable on candidate but baseline measured ${base}ms"
      return 1
    fi
    warn "latency $op: unmeasured on candidate and baseline — no bar applied"
    return 0
  fi
  if [ -n "$base" ] && [ "$base" != "-1" ]; then
    if [ "$cand" -gt "$LAT_FLOOR_MS" ] 2>/dev/null \
      && awk -v c="$cand" -v b="$base" -v r="$LAT_RATIO" 'BEGIN{exit !(c > b*r)}'; then
      log "latency $op RED: candidate ${cand}ms > ${LAT_RATIO}x baseline ${base}ms"
      return 1
    fi
    if [ "$cand" -gt "$LAT_ABS_MAX_MS" ] 2>/dev/null; then
      if [ "$base" -gt "$LAT_ABS_MAX_MS" ] 2>/dev/null; then
        warn "latency $op: candidate ${cand}ms AND baseline ${base}ms both exceed the ${LAT_ABS_MAX_MS}ms ceiling — pre-existing slowness, not a candidate regression; fix the store, not the upgrade"
      else
        warn "latency $op: candidate ${cand}ms over the ${LAT_ABS_MAX_MS}ms ceiling but within ${LAT_RATIO}x of baseline ${base}ms — WATCH it"
      fi
    fi
    log "latency $op GREEN: candidate=${cand}ms baseline=${base}ms (ratio bar ${LAT_RATIO}x above ${LAT_FLOOR_MS}ms)"
    return 0
  fi
  if [ "$cand" -gt "$LAT_ABS_MAX_MS" ] 2>/dev/null; then
    log "latency $op RED: candidate ${cand}ms > absolute ceiling ${LAT_ABS_MAX_MS}ms (no baseline to compare)"
    return 1
  fi
  log "latency $op GREEN: candidate=${cand}ms (no baseline; abs max ${LAT_ABS_MAX_MS}ms)"
  return 0
}

# Boot a lastdbd on a throwaway CoW of the primary; sample peak RSS after
# settle, then time the latency workload against the copy. Writes key=value
# metrics (boot_secs, peak_rss_mb, lat_point_ms, lat_scan_ms, lat_write_ms;
# -1 = unmeasured) to the out file. Non-zero rc = could not boot/serve.
probe_bin_metrics() {
  # $1 = lastdbd binary, $2 = label (candidate|baseline), $3 = metrics out file
  local bin="$1" label="$2" outf="$3"
  local copy sock blog pid uh i boot_secs max_rss rss
  local p_ms s_ms w_ms

  mkdir -p "$PROBE_ROOT"
  copy="$PROBE_ROOT/metrics-probe-${label}-$(date +%s)-$$"
  blog="$copy.boot.log"
  rm -rf "$copy"
  # Live sockets in the source home make cp exit non-zero even when the clone
  # is fine (same lesson as the backup step) — judge by essentials, not rc.
  cp -cR "$PRIMARY_HOME" "$copy" 2>/dev/null || true
  if [ ! -d "$copy" ] || [ ! -f "$copy/identity.key" ] || [ ! -d "$copy/data" ]; then
    warn "$label metrics probe: CoW clone incomplete"
    rm -rf "$copy" "$blog" 2>/dev/null || true
    return 1
  fi
  rm -f "$copy/cloud_sync.json" "$copy/data/"*.sock 2>/dev/null || true
  sock="$copy/data/folddb.sock"

  # Boot with the live node's LASTDB_* tuning so measurements reflect the
  # config that will actually serve after cutover.
  local env_pairs=()
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
      uh="$(curl -sS --max-time 3 --unix-socket "$sock" -H 'Host: localhost' http://x/api/system/auto-identity 2>/dev/null | jq -r '.user_hash // empty' 2>/dev/null || true)"
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
  boot_secs="$i"
  log "$label metrics probe: identity ready after ${boot_secs}s; settling ${RSS_SETTLE_SECS}s for embeddings/load..."
  sleep "$RSS_SETTLE_SECS"

  # Latency workload FIRST, sampling RSS after each op: an idle Last Store
  # node lazy-loads and gets compressed/paged by macOS, so idle RSS reads as
  # tiny (e2e 2026-07-28: 10 MiB "peak" on a 33G store) and the memory-guard
  # bar never fires. Peak RSS only means something measured under real load.
  max_rss=0
  sample_rss_into_max() {
    if kill -0 "$pid" 2>/dev/null; then
      rss="$(rss_mb_of_pid "$pid")"
      if [ "$rss" -gt "$max_rss" ] 2>/dev/null; then max_rss="$rss"; fi
    fi
  }
  p_ms=-1; s_ms=-1; w_ms=-1
  if [ "$LAT_SKIP" != "1" ]; then
    p_ms="$(measure_op_median_ms op_lat_point "$sock" "$label point-read")"
    sample_rss_into_max
    if command -v kanban >/dev/null 2>&1; then
      s_ms="$(measure_op_median_ms op_lat_scan "$copy" "$label kanban-scan")"
      sample_rss_into_max
    else
      warn "latency: kanban CLI not on PATH — scan op unmeasured"
    fi
    if command -v brain >/dev/null 2>&1; then
      w_ms="$(measure_op_median_ms op_lat_write "$copy" "$label brain-write")"
      sample_rss_into_max
    else
      warn "latency: brain CLI not on PATH — write op unmeasured"
    fi
  else
    warn "$label metrics probe: LAT_SKIP=1 — RSS will be sampled on an IDLE node and may understate load RSS"
  fi
  for i in $(seq 1 "$RSS_SAMPLE_SECS"); do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "$label metrics probe: node died during RSS sample window"
      break
    fi
    sample_rss_into_max
    sleep 1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$copy" "$blog" 2>/dev/null || true
    return 1
  fi

  kill "$pid" 2>/dev/null || true
  sleep 2
  kill -9 "$pid" 2>/dev/null || true
  rm -rf "$copy" "$blog" 2>/dev/null || true
  {
    echo "boot_secs=$boot_secs"
    echo "peak_rss_mb=$max_rss"
    echo "lat_point_ms=$p_ms"
    echo "lat_scan_ms=$s_ms"
    echo "lat_write_ms=$w_ms"
  } >"$outf"
  log "$label metrics: boot_s=${boot_secs} peak_rss_mb=${max_rss} point_ms=${p_ms} scan_ms=${s_ms} write_ms=${w_ms}"
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
    die "launchd job-definition reload failed; primary may be stopped. Inspect: launchctl print gui/${uid}/${LAUNCHD_LABEL}"
  fi

  # Wait for the reloaded instance's socket. Recovery after an unclean
  # prior exit can take 60-90s+, and starting a SECOND lastdbd against the
  # live home while the launchd one is still booting is exactly what produced
  # the 2026-07-17 boot storm (3 instances in 20s + "database is locked"
  # failures; card lastdb-safe-upgrade-cutover-supervisor-race). While the
  # launchd job exists, KeepAlive owns respawns — NEVER direct-start a rival.
  local wait_secs="${LASTDB_CUTOVER_SOCKET_WAIT_SECS:-180}"
  local waited=0
  while [ ! -S "$PRIMARY_SOCK" ] && [ "$waited" -lt "$wait_secs" ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ -S "$PRIMARY_SOCK" ]; then
    log "socket up after ${waited}s"
  elif launchctl print "gui/${uid}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    warn "socket still missing after ${wait_secs}s but launchd job is loaded — NOT direct-starting a second daemon (lock fight). Inspect: launchctl print gui/${uid}/${LAUNCHD_LABEL}; tail ~/.lastdb/last_boot_error.txt"
  else
    warn "no launchd job and no socket after ${wait_secs}s; starting $dest/lastdbd --data-dir $PRIMARY_HOME once"
    nohup "$dest/lastdbd" --data-dir "$PRIMARY_HOME" \
      >>"${LASTDB_MANUAL_LOG:-/opt/homebrew/var/log/lastdb/lastdbd.manual-cutover.log}" 2>&1 &
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
}

# --- preflight ---------------------------------------------------------------

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
  if ! curl -sS --max-time 5 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' http://x/health \
    | grep -q '"status":"ok"'; then
    die "primary socket exists but /health is not ok — fix the live brain before upgrading"
  fi
  log "primary /health: ok"
else
  warn "primary socket not present — service may be stopped; continuing with offline home"
fi

# --- resolve candidate binary ------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-safe-upgrade.XXXXXX")"
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

# RSS + latency metrics probe: one CoW boot of the candidate measures both.
# RSS incident 2026-07-22: post-cutover ~8.5G RSS vs 6G guard → thrash restarts.
# Latency incident 2026-07-25/27: 0.23.1 correct-but-5-20x-slower passed GREEN.
log "RSS bar: limit=$(resolve_rss_limit_mb)MiB fail_at>=$(rss_fail_threshold_mb "$(resolve_rss_limit_mb)")MiB (headroom ${RSS_HEADROOM_PCT}%) settle=${RSS_SETTLE_SECS}s sample=${RSS_SAMPLE_SECS}s"
CAND_METRICS="$WORK/cand.metrics"
set +e
probe_bin_metrics "$CANDIDATE_BIN" "candidate" "$CAND_METRICS"
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
CAND_LAT_POINT_MS="$(metric_val "$CAND_METRICS" lat_point_ms)"
CAND_LAT_SCAN_MS="$(metric_val "$CAND_METRICS" lat_scan_ms)"
CAND_LAT_WRITE_MS="$(metric_val "$CAND_METRICS" lat_write_ms)"

# Latency baseline: the CURRENT live binary on an identical CoW copy. Same
# data, same machine, same settle — the binary is the only variable.
BASE_LAT_POINT_MS="-1"
BASE_LAT_SCAN_MS="-1"
BASE_LAT_WRITE_MS="-1"
BASE_BOOT_SECS=""
if [ "$LAT_SKIP" != "1" ]; then
  BASELINE_BIN="$(resolve_baseline_bin)"
  if [ -n "$BASELINE_BIN" ] && [ -x "$BASELINE_BIN" ]; then
    log "latency baseline: booting current binary ($BASELINE_BIN) on its own CoW copy"
    BASE_METRICS="$WORK/base.metrics"
    set +e
    probe_bin_metrics "$BASELINE_BIN" "baseline" "$BASE_METRICS"
    BASE_METRICS_RC=$?
    set -e
    if [ "$BASE_METRICS_RC" -eq 0 ]; then
      BASE_BOOT_SECS="$(metric_val "$BASE_METRICS" boot_secs)"
      BASE_LAT_POINT_MS="$(metric_val "$BASE_METRICS" lat_point_ms)"
      BASE_LAT_SCAN_MS="$(metric_val "$BASE_METRICS" lat_scan_ms)"
      BASE_LAT_WRITE_MS="$(metric_val "$BASE_METRICS" lat_write_ms)"
    else
      warn "latency: baseline probe failed — applying absolute ceiling (${LAT_ABS_MAX_MS}ms) only"
    fi
  else
    warn "latency: no baseline binary resolvable — applying absolute ceiling (${LAT_ABS_MAX_MS}ms) only"
  fi

  # A much slower candidate boot usually means a migration ran on the probe
  # copy — it will run again at live cutover, so expect a longer restart.
  if [ -n "$BASE_BOOT_SECS" ] && [ -n "$CAND_BOOT_SECS" ] \
    && [ "$CAND_BOOT_SECS" -gt $((BASE_BOOT_SECS * 3)) ] 2>/dev/null \
    && [ "$CAND_BOOT_SECS" -gt $((BASE_BOOT_SECS + 60)) ] 2>/dev/null; then
    warn "candidate boot ${CAND_BOOT_SECS}s vs baseline ${BASE_BOOT_SECS}s — possible one-time migration; expect a longer live cutover window (not RED by itself)"
  fi

  LAT_RED=0
  LAT_RED_REASON=""
  lat_op_within_bar "point-read (Board title)" "$CAND_LAT_POINT_MS" "$BASE_LAT_POINT_MS" || {
    LAT_RED=1
    LAT_RED_REASON="per-op ratio (single-op ${LAT_RATIO}x bar)"
  }
  lat_op_within_bar "scan (kanban list)"       "$CAND_LAT_SCAN_MS"  "$BASE_LAT_SCAN_MS"  || {
    LAT_RED=1
    LAT_RED_REASON="per-op ratio (single-op ${LAT_RATIO}x bar)"
  }
  lat_op_within_bar "write (brain put)"        "$CAND_LAT_WRITE_MS" "$BASE_LAT_WRITE_MS" || {
    LAT_RED=1
    LAT_RED_REASON="per-op ratio (single-op ${LAT_RATIO}x bar)"
  }
  # Aggregate term: every-op moderate regression / geo-mean (2026-08-05).
  # Runs even when per-op is GREEN — that is the hole it closes.
  set +e
  CORR_OUT="$(lat_correlated_within_bar \
    "$CAND_LAT_POINT_MS" "$BASE_LAT_POINT_MS" \
    "$CAND_LAT_SCAN_MS"  "$BASE_LAT_SCAN_MS" \
    "$CAND_LAT_WRITE_MS" "$BASE_LAT_WRITE_MS")"
  CORR_RC=$?
  set -e
  if [ -n "$CORR_OUT" ]; then
    # Mirror pure-helper lines through the driver's log/warn channels.
    while IFS= read -r corr_line || [ -n "$corr_line" ]; do
      [ -n "$corr_line" ] || continue
      case "$corr_line" in
        *' RED:'*) log "$corr_line" ;;
        *'SKIPPED'*) warn "$corr_line" ;;
        *) log "$corr_line" ;;
      esac
    done <<EOF
$CORR_OUT
EOF
  fi
  if [ "$CORR_RC" -ne 0 ]; then
    LAT_RED=1
    LAT_RED_REASON="correlated regression (all-ops >=${LASTDB_PROBE_LAT_CORR_RATIO}x and/or geo-mean >${LASTDB_PROBE_LAT_GEO_MEAN_MAX}x)"
  fi
  if [ "$LAT_RED" -ne 0 ]; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: candidate $CAND_VER fails the latency bar (${LAT_RED_REASON:-unknown}) — correct-but-slow is NOT GREEN (incident 2026-07-25/27 single-op; 2026-08-05 correlated moderate regression)"
    echo "LATENCY: point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) ratio-bar=${LAT_RATIO}x floor=${LAT_FLOOR_MS}ms abs-max=${LAT_ABS_MAX_MS}ms corr-ratio=${LASTDB_PROBE_LAT_CORR_RATIO}x geo-mean-max=${LASTDB_PROBE_LAT_GEO_MEAN_MAX}x"
    echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
    echo "NEXT:   do NOT live-upgrade; profile the candidate's read/write paths (brain: lastdb-0231-hashgroup-scan-warmset-thrash-read-regression, papercut-safe-upgrade-latency-bar-blind-to-correlated-regression). Re-running with LASTDB_PROBE_LAT_SKIP=1 or LASTDB_PROBE_LAT_CORR_SKIP=1 requires Tom's explicit clearance."
    exit 1
  fi
else
  warn "latency bar SKIPPED (LASTDB_PROBE_LAT_SKIP=1) — Tom-clearance only; correct-but-slow will NOT be caught"
fi
log "probe GREEN for candidate $CAND_VER (data-plane + RSS peak_mb=${PROBE_RSS_MB} + latency point/scan/write=${CAND_LAT_POINT_MS}/${CAND_LAT_SCAN_MS}/${CAND_LAT_WRITE_MS}ms)"

if [ "$PROBE_ONLY" -eq 1 ]; then
  release_rollback_point
  echo ""
  echo "VERDICT: GREEN_PROBE_ONLY"
  echo "SUMMARY: candidate $CAND_VER boots and serves a CoW of real data; peak_rss_mb=${PROBE_RSS_MB} under guard limit=$(resolve_rss_limit_mb); latency within bar. Primary left on $CURRENT_VER."
  echo "ROLLBACK: released (probe GREEN; primary untouched)"
  echo "RSS:     peak_mb=${PROBE_RSS_MB} limit_mb=$(resolve_rss_limit_mb) fail_at_mb=$(rss_fail_threshold_mb "$(resolve_rss_limit_mb)")"
  echo "LATENCY: point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) boot=${CAND_BOOT_SECS}s(base ${BASE_BOOT_SECS:-?}s)"
  echo "NEXT:    re-run without --probe-only (and --yes if non-interactive) for venue-aware live cutover"
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

# Wait for live socket health
LIVE_OK=0
for i in $(seq 1 120); do
  if [ -S "$PRIMARY_SOCK" ] \
    && curl -sS --max-time 3 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' http://x/health 2>/dev/null \
      | grep -q '"status":"ok"'; then
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
  RUNNING_VERSION="$(curl -sS --max-time 15 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' \
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
UH="$(curl -sS --max-time 5 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' http://x/api/system/auto-identity 2>/dev/null | jq -r '.user_hash // empty')"
[ -n "$UH" ] || die "live auto-identity empty after cutover — treat as RED; consider restore from $BACKUP"
NSCHEMAS="$(curl -sS --max-time 30 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' http://x/api/schemas 2>/dev/null | jq -r '.schemas|length // 0')"
[ "${NSCHEMAS:-0}" -gt 0 ] || die "live /api/schemas empty after cutover — treat as RED; restore from $BACKUP"
QRES="$(curl -sS --max-time 30 --unix-socket "$PRIMARY_SOCK" -H 'Host: localhost' -H 'Content-Type: application/json' \
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
NOTICE_SUMMARY="lastdbd ${CURRENT_VER} → ${INSTALLED} with lastdb=${INSTALLED_CLI:-?} venue=${VENUE} cutover_s=${CUTOVER_SECS}; probe latency point/scan/write=${CAND_LAT_POINT_MS:-?}/${CAND_LAT_SCAN_MS:-?}/${CAND_LAT_WRITE_MS:-?}ms (baseline ${BASE_LAT_POINT_MS:-?}/${BASE_LAT_SCAN_MS:-?}/${BASE_LAT_WRITE_MS:-?}ms) live_point_ms=${LIVE_LAT_POINT_MS:-?} live_scan_ms=${LIVE_LAT_SCAN_MS:-?} durability=${DURABILITY_N}/${DURABILITY_N}; brief socket blips expected. Do not open a new incident or restart the primary for flapping alone. Design: lastdb-minimal-downtime-cutover."
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
echo "DATA ROLLBACK: not retained after GREEN. Any RED before this point keeps one"
echo "ephemeral CoW rollback point for ${ROLLBACK_TTL_HOURS}h; the next safe-upgrade run reclaims it."
exit 0
