#!/usr/bin/env bash
#
# Safe LastDB Mini upgrade against Tom's PRIMARY brain home.
#
# ALWAYS:
#   1. Create a durable offline backup of ~/.lastdb
#   2. Boot the CANDIDATE lastdbd against a throwaway CoW/probe copy
#   3. Require GREEN (identity decrypts, schemas load, real Board values)
#   4. Only then venue-aware live install:
#        sidebin → atomic install under bin-with-upload-cap + launchctl kickstart
#        brew    → brew upgrade + brew services restart (only if formula installed)
#   5. Post-check the LIVE home; print rollback if anything looks wrong
#
# Design: fold/docs/designs/lastdb-minimal-downtime-cutover.md
#
# NEVER:
#   - Run the candidate against the live ~/.lastdb before probe is GREEN
#   - Skip the backup
#   - Kill/restart the primary on a RED probe
#   - brew upgrade when formula is not installed / primary is sidebin+launchd
#
# Usage:
#   safe-upgrade-lastdb.sh                  # resolve → probe → live if green
#   safe-upgrade-lastdb.sh --probe-only     # backup + probe only (no live install)
#   safe-upgrade-lastdb.sh --yes            # no confirm prompt before live cutover
#   safe-upgrade-lastdb.sh --candidate /path/to/lastdbd
#   safe-upgrade-lastdb.sh --version 0.22.8 # fetch that tap release tarball
#
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:${PATH:-}"

PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
PRIMARY_SOCK="$PRIMARY_HOME/data/folddb.sock"
BACKUP_ROOT="${LASTDB_BACKUP_ROOT:-$HOME/.lastdb-backups}"
PROBE_ROOT="${LASTDB_PROBE_ROOT:-$HOME/.lastdb-test-copies}"
SMOKE_SH="${LASTDB_SMOKE_SH:-$HOME/code/edgevector/.claude/run-lastdb-mini-smoke.sh}"
TAP_REPO="EdgeVector/homebrew-lastdb"
# Live install venue (see fold/docs/designs/lastdb-minimal-downtime-cutover.md)
SIDEBIN_DIR="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}"
LAUNCHD_LABEL="${LASTDB_LAUNCHD_LABEL:-com.tomtang.lastdbd-primary-506}"
LAUNCHD_PLIST="${LASTDB_LAUNCHD_PLIST:-$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist}"


PROBE_ONLY=0
ASSUME_YES=0
CANDIDATE_BIN=""
TARGET_VERSION=""
WORK=""

usage() {
  sed -n '2,28p' "$0"
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe-only) PROBE_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --candidate) CANDIDATE_BIN="$2"; shift 2 ;;
    --version) TARGET_VERSION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[safe-upgrade] %s\n' "$*"; }
die() { printf '[safe-upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[safe-upgrade] WARN: %s\n' "$*" >&2; }

cleanup_work() {
  # Never delete durable backups. Only temp fetch dirs under $WORK.
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}
trap cleanup_work EXIT


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

live_install_sidebin() {
  local dest="$SIDEBIN_DIR"
  local ts cand_cli
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  [ -x "$CANDIDATE_BIN" ] || die "candidate not executable: $CANDIDATE_BIN"
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

  cand_cli="$(dirname "$CANDIDATE_BIN")/lastdb"
  if [ -x "$cand_cli" ]; then
    if [ -x "$dest/lastdb" ]; then
      cp -a "$dest/lastdb" "$dest/lastdb.bak-pre-${CAND_VER}-${ts}" 2>/dev/null || true
    fi
    cp -a "$cand_cli" "$dest/lastdb.new"
    chmod +x "$dest/lastdb.new"
  fi

  # Atomic-ish swap (same directory rename)
  mv -f "$dest/lastdbd.new" "$dest/lastdbd"
  if [ -f "$dest/lastdb.new" ]; then
    mv -f "$dest/lastdb.new" "$dest/lastdb"
  fi
  log "installed candidate into $dest/lastdbd"

  local uid
  uid="$(id -u)"
  CUTOVER_T0="$(date +%s)"
  if launchctl print "gui/${uid}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    log "launchctl kickstart -k gui/${uid}/${LAUNCHD_LABEL}"
    launchctl kickstart -k "gui/${uid}/${LAUNCHD_LABEL}" \
      || warn "kickstart failed; will poll socket / try direct start"
  else
    warn "launchd job not loaded; bootstrapping $LAUNCHD_PLIST"
    if [ -f "$LAUNCHD_PLIST" ]; then
      launchctl bootstrap "gui/${uid}" "$LAUNCHD_PLIST" 2>/dev/null \
        || launchctl load "$LAUNCHD_PLIST" 2>/dev/null \
        || true
      launchctl kickstart "gui/${uid}/${LAUNCHD_LABEL}" 2>/dev/null || true
    fi
  fi

  # Wait for the kickstarted instance's socket. Recovery after an unclean
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

CURRENT_VER="$(lastdbd --version 2>/dev/null | awk '{print $NF}' || true)"
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

if [ "$CAND_VER" = "$CURRENT_VER" ] && [ "$PROBE_ONLY" -eq 0 ]; then
  log "candidate matches current; no upgrade needed"
  echo "VERDICT: ALREADY_CURRENT"
  exit 0
fi

# --- 1) durable offline backup -----------------------------------------------

mkdir -p "$BACKUP_ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_ROOT/pre-${CAND_VER}-from-${CURRENT_VER}-${TS}"
log "STEP 1/4: durable backup → $BACKUP"
# Prefer APFS clone for speed. A *live* primary races with the copy:
#   - UDS sockets under data/*.sock (not copyable)
#   - CAS blob files that vanish mid-walk
# Those produce non-zero `cp` exit even when identity + store data are cloned.
# Treat clone as OK when essential files land; only fall back to rsync when not.
# Never use bare `cp -a` of a multi-GB live home when disk is tight (fills disk).
backup_essentials_ok() {
  local root="$1"
  # identity + data dir required. Storage is either legacy sled (data/db) or
  # Last Store collections under data/data/ (Mini LASTDB_ENGINE=laststore).
  [ -f "$root/identity.key" ] && [ -d "$root/data" ] || return 1
  [ -e "$root/data/db" ] || [ -d "$root/data/data" ] || [ -d "$root/data/laststore" ]
}
set +e
cp -cR "$PRIMARY_HOME" "$BACKUP" 2>"$WORK/backup.err"
CP_RC=$?
set -e
if backup_essentials_ok "$BACKUP"; then
  log "backup: APFS clone (cp -cR exit=$CP_RC; live sockets/vanished blobs tolerated)"
  if [ "$CP_RC" -ne 0 ] && [ -s "$WORK/backup.err" ]; then
    log "backup: non-fatal cp notes (first 5 lines):"
    head -5 "$WORK/backup.err" | while IFS= read -r line; do log "  $line"; done
  fi
else
  rm -rf "$BACKUP"
  mkdir -p "$BACKUP"
  log "backup: APFS clone incomplete — rsync fallback (excludes *.sock)"
  set +e
  rsync -a --exclude='*.sock' "$PRIMARY_HOME/" "$BACKUP/" 2>"$WORK/backup-rsync.err"
  RSYNC_RC=$?
  set -e
  backup_essentials_ok "$BACKUP" || die "backup failed (cp exit=$CP_RC rsync exit=$RSYNC_RC); see $WORK/backup.err"
  log "backup: rsync ok (exit=$RSYNC_RC)"
fi
[ -d "$BACKUP" ] || die "backup failed"
[ ! -L "$BACKUP" ] || die "backup resolved to a symlink (unsafe)"
# Refuse aliasing live data
BDATA="$(cd "$BACKUP/data" 2>/dev/null && pwd -P || true)"
LDATA="$(cd "$PRIMARY_HOME/data" 2>/dev/null && pwd -P || true)"
[ -n "$BDATA" ] && [ "$BDATA" != "$LDATA" ] || die "backup data dir aliases live primary"
log "backup ok ($(du -sh "$BACKUP" 2>/dev/null | awk '{print $1}'))"

# --- 2) probe candidate on a throwaway CoW of the primary --------------------

log "STEP 2/4: probe candidate $CAND_VER against CoW copy of primary (never live home)"
# The smoke harness clones PRIMARY_HOME itself and boots BIN. We only pass BIN.
set +e
SMOKE_OUT="$WORK/smoke.out"
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
log "probe GREEN for candidate $CAND_VER"

if [ "$PROBE_ONLY" -eq 1 ]; then
  echo ""
  echo "VERDICT: GREEN_PROBE_ONLY"
  echo "SUMMARY: candidate $CAND_VER boots and serves a CoW of real data. Primary left on $CURRENT_VER."
  echo "BACKUP:  $BACKUP"
  echo "NEXT:    re-run without --probe-only (and --yes if non-interactive) for venue-aware live cutover"
  exit 0
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
    echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
  else
    echo "  brew upgrade edgevector/lastdb/lastdb"
    echo "  brew services restart lastdb"
  fi
  echo "  post-check live /health + Board title"
  echo "Backup remains at: $BACKUP"
  printf "Proceed with LIVE upgrade? [y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log "aborted by user; primary still on $CURRENT_VER; backup kept"; exit 0 ;;
  esac
fi

# --- 4) live upgrade (venue-aware) -------------------------------------------

log "STEP 3/4: live install + supervisor restart (venue=$VENUE)"
CUTOVER_T0="$(date +%s)"

if [ "$VENUE" = "sidebin" ]; then
  live_install_sidebin
  INSTALLED="$("$SIDEBIN_DIR/lastdbd" --version 2>/dev/null | awk '{print $NF}' || true)"
else
  live_install_brew
  INSTALLED="$(lastdbd --version 2>/dev/null | awk '{print $NF}' || true)"
fi

log "installed lastdbd --version: $INSTALLED"
[ -n "$INSTALLED" ] || warn "could not read installed --version"
[ "$INSTALLED" = "$CAND_VER" ] || warn "installed version ($INSTALLED) != candidate ($CAND_VER)"

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

CUTOVER_T1="$(date +%s)"
CUTOVER_SECS=$((CUTOVER_T1 - CUTOVER_T0))
log "STEP 4/4: live post-check GREEN (schemas=$NSCHEMAS first Board title=\"$QVAL\" cutover_s=$CUTOVER_SECS venue=$VENUE)"

# Post a Situations notice so other agents attribute post-upgrade flapping.
POST_NOTICE=""
for cand in \
  "${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-post-notice" \
  "$HOME/code/edgevector/last-stack/bin/last-stack-post-notice"
do
  [ -x "$cand" ] && POST_NOTICE="$cand" && break
done
NOTICE_SUMMARY="lastdbd ${CURRENT_VER} → ${INSTALLED} venue=${VENUE} cutover_s=${CUTOVER_SECS}; brief socket blips expected. Do not open a new incident or restart the primary for flapping alone. Design: lastdb-minimal-downtime-cutover."
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

echo ""
echo "VERDICT: GREEN"
echo "SUMMARY: upgraded lastdbd $CURRENT_VER → $INSTALLED; venue=$VENUE; cutover_s=$CUTOVER_SECS; probe + live Board read OK; backup at $BACKUP"
echo ""
echo "ROLLBACK (binary only, if new binary misbehaves but data is fine):"
if [ "$VENUE" = "sidebin" ]; then
  echo "  cp -a $SIDEBIN_DIR/lastdbd.bak-pre-${CAND_VER}-* $SIDEBIN_DIR/lastdbd   # pick newest bak"
  echo "  launchctl kickstart -k gui/\$(id -u)/$LAUNCHD_LABEL"
else
  echo "  brew services stop lastdb"
  echo "  brew reinstall edgevector/lastdb/lastdb  # or prior bottle"
  echo "  brew services start lastdb"
fi
echo ""
echo "ROLLBACK (data — only if home corrupted):"
echo "  # stop supervisor, move broken home aside, restore backup:"
echo "  mv $PRIMARY_HOME ${PRIMARY_HOME}.broken-\$(date +%Y%m%dT%H%M%S)"
echo "  cp -a $BACKUP $PRIMARY_HOME"
echo "  # then start supervisor (sidebin kickstart or brew services start)"
exit 0
