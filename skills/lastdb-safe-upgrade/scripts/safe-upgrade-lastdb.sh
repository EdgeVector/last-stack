#!/usr/bin/env bash
#
# Safe LastDB Mini upgrade against Tom's PRIMARY brain home.
#
# ALWAYS:
#   1. Create a durable offline backup of ~/.lastdb
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
#   4. Only then venue-aware live install:
#        sidebin → atomic install under bin-with-upload-cap + launchctl kickstart
#        brew    → brew upgrade + brew services restart (only if formula installed)
#   5. Post-check the LIVE home (incl. live RSS vs guard); print rollback if wrong
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
LAUNCHD_LABEL="${LASTDB_LAUNCHD_LABEL:-com.REPLACE.lastdbd-primary-506}"
LAUNCHD_PLIST="${LASTDB_LAUNCHD_PLIST:-$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist}"


PROBE_ONLY=0
ASSUME_YES=0
CANDIDATE_BIN=""
TARGET_VERSION=""
WORK=""

usage() {
  sed -n '2,34p' "$0"
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

# Memory-guard ceiling used by com.REPLACE.lastdbd-memory-guard (Tom, 2026-07-14).
# Env LASTDBD_RSS_LIMIT_MB wins; else LaunchAgent plist(s); else the resident
# primary default. Keep the primary daemon's own plist aligned before kickstart
# so lastdbd does not boot with its lower binary default while the guard allows
# the larger resident ceiling.
# Probe/live must stay under this or the guard SIGTERMs primary in a thrash loop
# (incident after 2026-07-22 sled-free cutover: candidate ~8.5G vs limit 6G).
MEMORY_GUARD_PLIST="${LASTDBD_MEMORY_GUARD_PLIST:-$HOME/Library/LaunchAgents/com.REPLACE.lastdbd-memory-guard.plist}"
DEFAULT_LASTDBD_RSS_LIMIT_MB="${LASTDBD_DEFAULT_RSS_LIMIT_MB:-12288}"
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

# Candidate class gates (incident 2026-08-01: primary cut over to worktree
# target/debug/lastdbd …-dirty). Sourced pure helpers.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=candidate-class-checks.sh
. "$_SCRIPT_DIR/candidate-class-checks.sh"

cleanup_work() {
  # Never delete durable backups. Only temp fetch dirs under $WORK.
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
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

find_reusable_backup() {
  # Always return 0: "no reusable backup" is normal for a brand-new candidate.
  # Under set -e, a bare assignment REUSABLE_BACKUP="$(find_reusable_backup ...)"
  # aborts the whole script if this function returns non-zero when found is empty
  # (papercut-safe-upgrade-probe-only-false-red-find-reusable-backup).
  local cand_ver="$1" current_ver="$2" candidate found
  found=""
  for candidate in "$BACKUP_ROOT"/pre-"$cand_ver"-from-"$current_ver"-*; do
    [ -e "$candidate" ] || continue
    if backup_essentials_ok "$candidate" && backup_data_is_not_live "$candidate"; then
      found="$candidate"
    fi
  done
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
  fi
  return 0
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

live_lastdb_env_pairs() {
  # LASTDB_* EnvironmentVariables from the live LaunchAgent plist, KEY=VAL per
  # line, so probe nodes boot with the primary's tuning (warm budget, atom
  # limit, …). Without this, probes measure default-config behavior the live
  # node does not have (e2e 2026-07-28: probe scan 43s vs live ~23s purely from
  # the missing 4 GiB LASTDB_HASH_GROUP_WARM_BYTES). HOME-shaped keys are
  # excluded — the probe must only ever see its own --data-dir copy.
  [ -f "$LAUNCHD_PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$LAUNCHD_PLIST" 2>/dev/null \
    | awk -F' = ' '
        $1 ~ /^ *LASTDB_/ {
          key=$1; gsub(/^ +| +$/,"",key)
          if (key == "LASTDB_HOME" || key == "FOLDDB_HOME" || key == "LASTDB_DATA_DIR") next
          val=$2; gsub(/^ +| +$/,"",val)
          if (key != "" && val != "") print key "=" val
        }'
}

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

ensure_primary_launchd_rss_limit() {
  local limit current
  if [ ! -f "$LAUNCHD_PLIST" ]; then
    warn "primary LaunchAgent plist missing ($LAUNCHD_PLIST); cannot stamp LASTDBD_RSS_LIMIT_MB before kickstart"
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

  ensure_primary_launchd_rss_limit

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

# --- 0) candidate class bar (before multi-GB backup) -------------------------
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

# --- 1) durable offline backup -----------------------------------------------

mkdir -p "$BACKUP_ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_ROOT/pre-${CAND_VER}-from-${CURRENT_VER}-${TS}"
# Prefer APFS clone for speed. A *live* primary races with the copy:
#   - UDS sockets under data/*.sock (not copyable)
#   - CAS blob files that vanish mid-walk
# Those produce non-zero `cp` exit even when identity + store data are cloned.
# Treat clone as OK when essential files land; only fall back to rsync when not.
# Never use bare `cp -a` of a multi-GB live home when disk is tight (fills disk).
REUSABLE_BACKUP=""
if [ "$PROBE_ONLY" -eq 1 ]; then
  REUSABLE_BACKUP="$(find_reusable_backup "$CAND_VER" "$CURRENT_VER")"
fi
if [ -n "$REUSABLE_BACKUP" ]; then
  BACKUP="$REUSABLE_BACKUP"
  log "STEP 1/4: durable backup → $BACKUP (reusing valid same-version probe backup)"
  log "backup: reuse existing pre-${CAND_VER}-from-${CURRENT_VER} backup"
else
  log "STEP 1/4: durable backup → $BACKUP"
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
fi
[ -d "$BACKUP" ] || die "backup failed"
[ ! -L "$BACKUP" ] || die "backup resolved to a symlink (unsafe)"
backup_data_is_not_live "$BACKUP" || die "backup data dir aliases live primary"
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
log "data-plane probe GREEN for candidate $CAND_VER"

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
  lat_op_within_bar "point-read (Board title)" "$CAND_LAT_POINT_MS" "$BASE_LAT_POINT_MS" || LAT_RED=1
  lat_op_within_bar "scan (kanban list)"       "$CAND_LAT_SCAN_MS"  "$BASE_LAT_SCAN_MS"  || LAT_RED=1
  lat_op_within_bar "write (brain put)"        "$CAND_LAT_WRITE_MS" "$BASE_LAT_WRITE_MS" || LAT_RED=1
  if [ "$LAT_RED" -ne 0 ]; then
    echo ""
    echo "VERDICT: RED"
    echo "REASON: candidate $CAND_VER fails the latency bar — correct-but-slow is NOT GREEN (incident 2026-07-25/27: 0.23.1 scans ran 5-20x slower and the old bar passed it)"
    echo "LATENCY: point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) ratio-bar=${LAT_RATIO}x floor=${LAT_FLOOR_MS}ms abs-max=${LAT_ABS_MAX_MS}ms"
    echo "BACKUP: $BACKUP  (kept; primary NOT upgraded)"
    echo "NEXT:   do NOT live-upgrade; profile the candidate's read/write paths (brain: lastdb-0231-hashgroup-scan-warmset-thrash-read-regression). Re-running with LASTDB_PROBE_LAT_SKIP=1 requires Tom's explicit clearance."
    exit 1
  fi
else
  warn "latency bar SKIPPED (LASTDB_PROBE_LAT_SKIP=1) — Tom-clearance only; correct-but-slow will NOT be caught"
fi
log "probe GREEN for candidate $CAND_VER (data-plane + RSS peak_mb=${PROBE_RSS_MB} + latency point/scan/write=${CAND_LAT_POINT_MS}/${CAND_LAT_SCAN_MS}/${CAND_LAT_WRITE_MS}ms)"

if [ "$PROBE_ONLY" -eq 1 ]; then
  echo ""
  echo "VERDICT: GREEN_PROBE_ONLY"
  echo "SUMMARY: candidate $CAND_VER boots and serves a CoW of real data; peak_rss_mb=${PROBE_RSS_MB} under guard limit=$(resolve_rss_limit_mb); latency within bar. Primary left on $CURRENT_VER."
  echo "BACKUP:  $BACKUP"
  echo "RSS:     peak_mb=${PROBE_RSS_MB} limit_mb=$(resolve_rss_limit_mb) fail_at_mb=$(rss_fail_threshold_mb "$(resolve_rss_limit_mb)")"
  echo "LATENCY: point=${CAND_LAT_POINT_MS}ms(base ${BASE_LAT_POINT_MS}ms) scan=${CAND_LAT_SCAN_MS}ms(base ${BASE_LAT_SCAN_MS}ms) write=${CAND_LAT_WRITE_MS}ms(base ${BASE_LAT_WRITE_MS}ms) boot=${CAND_BOOT_SECS}s(base ${BASE_BOOT_SECS:-?}s)"
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

# Live RSS vs memory-guard (settle briefly — embeddings may still be loading).
log "live RSS settle ${RSS_SETTLE_SECS}s then sample ${RSS_SAMPLE_SECS}s..."
sleep "$RSS_SETTLE_SECS"
LIVE_PID=""
if [ -S "$PRIMARY_SOCK" ]; then
  LIVE_PID="$(lsof -t "$PRIMARY_SOCK" 2>/dev/null | head -1 || true)"
fi
if [ -z "${LIVE_PID:-}" ]; then
  LIVE_PID="$(pgrep -f "$SIDEBIN_DIR/lastdbd\$|$SIDEBIN_DIR/lastdbd " 2>/dev/null | head -1 || true)"
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
log "STEP 4/4: live post-check GREEN (schemas=$NSCHEMAS first Board title=\"$QVAL\" cutover_s=$CUTOVER_SECS venue=$VENUE peak_rss_mb=${LIVE_RSS_MB:-unknown} live_point_ms=${LIVE_LAT_POINT_MS:-unmeasured} live_scan_ms=${LIVE_LAT_SCAN_MS:-unmeasured})"

# Post a Situations notice so other agents attribute post-upgrade flapping.
POST_NOTICE=""
for cand in \
  "${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-post-notice" \
  "$HOME/code/edgevector/last-stack/bin/last-stack-post-notice"
do
  [ -x "$cand" ] && POST_NOTICE="$cand" && break
done
NOTICE_SUMMARY="lastdbd ${CURRENT_VER} → ${INSTALLED} venue=${VENUE} cutover_s=${CUTOVER_SECS}; probe latency point/scan/write=${CAND_LAT_POINT_MS:-?}/${CAND_LAT_SCAN_MS:-?}/${CAND_LAT_WRITE_MS:-?}ms (baseline ${BASE_LAT_POINT_MS:-?}/${BASE_LAT_SCAN_MS:-?}/${BASE_LAT_WRITE_MS:-?}ms) live_point_ms=${LIVE_LAT_POINT_MS:-?} live_scan_ms=${LIVE_LAT_SCAN_MS:-?}; brief socket blips expected. Do not open a new incident or restart the primary for flapping alone. Design: lastdb-minimal-downtime-cutover."
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
echo "SUMMARY: upgraded lastdbd $CURRENT_VER → $INSTALLED; venue=$VENUE; cutover_s=$CUTOVER_SECS; probe + live Board read OK; probe_rss_mb=${PROBE_RSS_MB:-?} live_rss_mb=${LIVE_RSS_MB:-?} limit_mb=$(resolve_rss_limit_mb); backup at $BACKUP"
echo "LATENCY: probe point/scan/write=${CAND_LAT_POINT_MS:-?}/${CAND_LAT_SCAN_MS:-?}/${CAND_LAT_WRITE_MS:-?}ms baseline=${BASE_LAT_POINT_MS:-?}/${BASE_LAT_SCAN_MS:-?}/${BASE_LAT_WRITE_MS:-?}ms live_point=${LIVE_LAT_POINT_MS:-?}ms live_scan=${LIVE_LAT_SCAN_MS:-?}ms"
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
