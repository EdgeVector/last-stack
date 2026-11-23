#!/usr/bin/env bash
#
# Safe LastDB Mini upgrade of Tom's PRIMARY home (native format 15 and newer).
#
# NO COPY OF THE PRIMARY DATABASE (Tom, 2026-10-12): nothing here copies the
# primary home or boots a node on a copy of it. Every trial runs on generated
# data in a fresh home. Brain:
# decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data
#
# ALWAYS, in this order:
#   1. Bind the exact candidate pair (lastdbd + lastdb) to the Loom tuple and
#      to the attested GitHub release with passing exact-source CI checks
#      (ci-required, benchmark-complete). No local build or benchmark runs.
#   2. Refuse debug, -dirty and oversized candidates (candidate class bar).
#   3. Open a generated home with the old build, then the candidate, then the
#      old build again (keyed reads, memory bar): native-primary-probe.py.
#   4. DEV restore proof: a generated home with a new identity writes records,
#      backs up to the DEV relay with the candidate pair, restores from the
#      recovery phrase into a fresh home, and the records match key by key:
#      dev-restore-proof.py.
#   5. Pre-live: the primary is healthy, supervised, and Brain and LastSecrets
#      locators read back.
#   6. Live: stage the exact pair under native-run-v2-programs/<full commit>,
#      require the recovery point in the OLD build status (backup connected,
#      no error, a snapshot, acked == head), strict stop with a flush receipt,
#      switch ProgramArguments:0 and the current link, bootstrap the job.
#   7. Soak five minutes (health, identity, memory, locators), then require
#      acked to follow head again and one `lastdb backup snapshot --wait`.
#
# NEVER:
#   - Run the candidate against the live ~/.lastdb before the trials are GREEN
#   - Copy the primary home for any reason
#   - Install only lastdbd without the sibling lastdb CLI from the same build
#   - Kill/restart the primary on a RED trial
#   - Read the primary recovery phrase. Restoring the primary is Tom's own act.
#
# Usage:
#   safe-upgrade-lastdb.sh --candidate /path/to/lastdbd --probe-only
#   safe-upgrade-lastdb.sh --version 0.22.8 --probe-only   # fetch that tap release tarball
#   safe-upgrade-lastdb.sh --live-read-check               # one keyed live read
#
# Live cutovers run only as a Loom lastdb-safe-upgrade graph node. Use
# last-stack-safe-upgrade-loom --candidate /path/to/lastdbd.
#
set -euo pipefail

# Prefer sidebin primary binary over Homebrew so CURRENT_VER reflects the
# live LaunchAgent daemon, not whatever brew last linked (canary bottles often
# land in /opt/homebrew/bin and false-trigger ALREADY_CURRENT).
export PATH="${LASTDB_SIDEBIN_DIR:-$HOME/.lastdb/bin-with-upload-cap}:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:${PATH:-}"

PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
PRIMARY_SOCK="$PRIMARY_HOME/data/folddb.sock"
_home_real="$(cd "$HOME" && pwd -P)"
TAP_REPO="EdgeVector/homebrew-lastdb"
# Recovery state field kept for cutover-timeout-recovery.sh.
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
LIVE_READ_CHECK=0
CANDIDATE_BIN=""
CANDIDATE_CLI_BIN=""
TARGET_VERSION=""
WORK=""

usage() {
  sed -n '2,43p' "$0"
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe-only) PROBE_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --live-read-check) LIVE_READ_CHECK=1; shift ;;
    --candidate) CANDIDATE_BIN="$2"; shift 2 ;;
    --version) TARGET_VERSION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[safe-upgrade] %s\n' "$*"; }
die() { printf '[safe-upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[safe-upgrade] WARN: %s\n' "$*" >&2; }

if [ "$PROBE_ONLY" -eq 0 ] && [ "$LIVE_READ_CHECK" -eq 0 ]; then
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

SAFE_UPGRADE_APPS_OFF="${LASTDB_SAFE_UPGRADE_APPS_OFF:-1}"
LIVE_CONFIG_ENFORCE="${LASTDB_LIVE_CONFIG_ENFORCE:-0}" # 1 = missing plist env keys are RED

# Candidate class gates (incident 2026-08-01: primary cut over to worktree
# target/debug/lastdbd …-dirty). Sourced pure helpers.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=candidate-class-checks.sh
. "$_SCRIPT_DIR/candidate-class-checks.sh"
# shellcheck source=binary-pair-checks.sh
. "$_SCRIPT_DIR/binary-pair-checks.sh"
# shellcheck source=candidate-binding.sh
. "$_SCRIPT_DIR/candidate-binding.sh"
# shellcheck source=launchd-job-checks.sh
. "$_SCRIPT_DIR/launchd-job-checks.sh"
# shellcheck source=live-socket-health.sh
. "$_SCRIPT_DIR/live-socket-health.sh"
# shellcheck source=signed-log-backup.sh
. "$_SCRIPT_DIR/signed-log-backup.sh"
# shellcheck source=programs-venue.sh
. "$_SCRIPT_DIR/programs-venue.sh"
# shellcheck source=native-primary.sh
. "$_SCRIPT_DIR/native-primary.sh"
# shellcheck source=owner-lock.sh
. "$_SCRIPT_DIR/owner-lock.sh"
# shellcheck source=deadline.sh
. "$_SCRIPT_DIR/deadline.sh"
DEV_RESTORE_PROOF_PY="$_SCRIPT_DIR/dev-restore-proof.py"

OWNER_LOCK_DIR="${LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR:-/tmp/lastdb-safe-upgrade-owner-${UID:-$(id -u)}.lock.d}"
OWNER_LOCK_TOKEN="$$.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
OWNER_LOCK_HELD=0
DRIVER_ENDED_STEP=0
SIDEBIN_BACKUP_DAEMON=""
SIDEBIN_BACKUP_CLI=""
CUTOVER_RECOVERY_STATE_TMP=""
OLD_PRIMARY_PID=""
OLD_PRIMARY_START_TS=""
OLD_PRIMARY_PS_LSTART=""

cleanup_work() {
  local rc=$?
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  [ -n "${CUTOVER_LOCK:-}" ] && rm -f "$CUTOVER_LOCK"
  [ -n "${CUTOVER_RECOVERY_STATE_TMP:-}" ] && rm -f "$CUTOVER_RECOVERY_STATE_TMP"
  # A stopped primary must not stay held after this run exits; the guard then
  # revives whatever program the plist names.
  if [ "${NATIVE_STOP_ARMED:-0}" != 1 ]; then
    if type programs_release_revive_hold >/dev/null 2>&1; then
      programs_release_revive_hold
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

write_cutover_recovery_state() {
  # The Loom wrapper owns this mode-600 file and removes it after CUTOVER.
  # Record the old process identity before the first stop. Recovery never
  # kills a process that may still be in its flush drain.
  local stage="$1" effect_started="$2"
  local state="${LASTDB_CUTOVER_RECOVERY_STATE:-}"
  local daemon_sha="" cli_sha=""
  [ -n "$state" ] || return 0
  case "$state" in /*) ;; *) die "cutover recovery state path is not absolute" ;; esac
  [ -f "$state" ] && [ ! -L "$state" ] \
    || die "cutover recovery state is absent or unsafe: $state"
  if stat --version >/dev/null 2>&1; then
    state_owner="$(stat -c '%u' "$state")"
    state_mode="$(stat -c '%a' "$state")"
  else
    state_owner="$(stat -f '%u' "$state")"
    state_mode="$(stat -f '%Lp' "$state")"
  fi
  [ "$state_owner" = "$(id -u)" ] \
    || die "cutover recovery state has the wrong owner"
  [ "$state_mode" = 600 ] \
    || die "cutover recovery state must have mode 600"
  [ "$effect_started" = true ] || [ "$effect_started" = false ] \
    || die "cutover recovery state has an invalid effect flag"
  if [ -n "${SIDEBIN_BACKUP_DAEMON:-}" ] && [ -f "$SIDEBIN_BACKUP_DAEMON" ]; then
    daemon_sha="$(binding_sha256_file "$SIDEBIN_BACKUP_DAEMON")"
  fi
  if [ -n "${SIDEBIN_BACKUP_CLI:-}" ] && [ -f "$SIDEBIN_BACKUP_CLI" ]; then
    cli_sha="$(binding_sha256_file "$SIDEBIN_BACKUP_CLI")"
  fi
  CUTOVER_RECOVERY_STATE_TMP="${state}.tmp.$$.$RANDOM"
  (
    umask 077
    jq -cn \
      --argjson state_version 3 \
      --arg loom_execution_id "${LOOM_EXEC_ID:-}" \
      --arg stage "$stage" \
      --argjson effect_started "$effect_started" \
      --arg venue "${VENUE:-}" \
      --arg primary_home "$PRIMARY_HOME" \
      --arg primary_socket "$PRIMARY_SOCK" \
      --arg old_pid "${OLD_PRIMARY_PID:-}" \
      --arg old_start_ts "${OLD_PRIMARY_START_TS:-}" \
      --arg old_ps_lstart "${OLD_PRIMARY_PS_LSTART:-}" \
      --arg sidebin_dir "$SIDEBIN_DIR" \
      --arg launchd_label "$LAUNCHD_LABEL" \
      --arg launchd_plist "$LAUNCHD_PLIST" \
      --arg backup_lastdbd "${SIDEBIN_BACKUP_DAEMON:-}" \
      --arg backup_lastdb "${SIDEBIN_BACKUP_CLI:-}" \
      --arg backup_lastdbd_sha256 "$daemon_sha" \
      --arg backup_lastdb_sha256 "$cli_sha" \
      --arg signed_program_dir "${NEW_PROGRAM_DIR:-}" \
      --arg signed_program_version "${CAND_VER:-}" \
      --arg signed_daemon_sha "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}" \
      --arg signed_cli_sha "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}" \
      '{state_version:$state_version,loom_execution_id:$loom_execution_id,
        stage:$stage,effect_started:$effect_started,venue:$venue,
        primary_home:$primary_home,primary_socket:$primary_socket,
        old_pid:$old_pid,old_start_ts:$old_start_ts,
        old_ps_lstart:$old_ps_lstart,
        sidebin_dir:$sidebin_dir,launchd_label:$launchd_label,
        launchd_plist:$launchd_plist,backup_lastdbd:$backup_lastdbd,
        backup_lastdb:$backup_lastdb,backup_lastdbd_sha256:$backup_lastdbd_sha256,
        backup_lastdb_sha256:$backup_lastdb_sha256}
        + (if $stage == "signed-programs-starting" then
            {signed_program_dir:$signed_program_dir, signed_program_version:$signed_program_version,
             signed_daemon_sha:$signed_daemon_sha, signed_cli_sha:$signed_cli_sha}
           else {} end)' \
      >"$CUTOVER_RECOVERY_STATE_TMP"
    chmod 600 "$CUTOVER_RECOVERY_STATE_TMP"
    mv -f "$CUTOVER_RECOVERY_STATE_TMP" "$state"
  ) || die "could not atomically update the cutover recovery state"
  CUTOVER_RECOVERY_STATE_TMP=""
  log "cutover recovery state: stage=$stage effect_started=$effect_started"
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

rss_fail_threshold_mb() {
  local limit="$1" headroom="$RSS_HEADROOM_PCT"
  if ! [ "$headroom" -ge 0 ] 2>/dev/null; then headroom=10; fi
  if [ "$headroom" -gt 50 ]; then headroom=50; fi
  echo $((limit * (100 - headroom) / 100))
}

# Live primary proof.
# Board stays the proof when that schema answers.
# A primary with no Board uses one brain record and one LastSecrets locator.
# Classify the mode before the live install. A miss leaves the primary unchanged.
# The query body is never logged. The secret text field is never requested.
live_read_slug_ok() {
  printf '%s\n' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$'
}

load_live_read_slugs() {
  local file line key_count
  if live_read_slug_ok "${LASTDB_LIVE_BRAIN_SLUG:-}" \
      && live_read_slug_ok "${LASTDB_LIVE_SECRET_SLUG:-}"; then
    return 0
  fi
  file="${LASTDB_LIVE_READ_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/lastdb-nightly-primary-upgrade/live-read.env}"
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    return 1
  fi
  if [ "$(stat -f '%u' "$file")" != "$(id -u)" ]; then
    return 1
  fi
  if [ "$(stat -f '%Lp' "$file")" != "600" ]; then
    return 1
  fi
  LASTDB_LIVE_BRAIN_SLUG=""
  LASTDB_LIVE_SECRET_SLUG=""
  key_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      LASTDB_LIVE_BRAIN_SLUG=*)
        LASTDB_LIVE_BRAIN_SLUG="${line#LASTDB_LIVE_BRAIN_SLUG=}"
        key_count=$((key_count + 1))
        ;;
      LASTDB_LIVE_SECRET_SLUG=*)
        LASTDB_LIVE_SECRET_SLUG="${line#LASTDB_LIVE_SECRET_SLUG=}"
        key_count=$((key_count + 1))
        ;;
      *) return 1 ;;
    esac
  done <"$file"
  [ "$key_count" -eq 2 ] || return 1
  live_read_slug_ok "$LASTDB_LIVE_BRAIN_SLUG" \
    && live_read_slug_ok "$LASTDB_LIVE_SECRET_SLUG"
}

primary_board_read_ok() {
  local payload out
  payload='{"reads":[{"schema":"Board","key":{"hash":"default"},"limit":1}]}'
  out="$(mktemp "${TMPDIR:-/tmp}/lastdb-live-board.XXXXXX")"
  chmod 600 "$out" || { rm -f "$out"; return 1; }
  if ! curl -fsS --max-time 30 --unix-socket "$PRIMARY_SOCK" \
      -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
      -H 'Content-Type: application/json' \
      --data "$payload" http://x/v1/read >"$out" 2>/dev/null; then
    rm -f "$out"
    return 1
  fi
  if ! jq -e '
      (.results | type == "array" and length == 1)
      and (.results[0] | has("error") | not)
      and (.results[0].records | type == "array" and length > 0)
      and ((.results[0].records[0].record.title // "") | length) > 0
    ' "$out" >/dev/null 2>&1; then
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

# Marker primary_brain_and_secret_ok: the nightly gate refuses Loom without it.
primary_brain_and_secret_ok() {
  local payload out schema="${LASTDB_LIVE_BRAIN_SCHEMA:-brain/Decision}"
  load_live_read_slugs || return 1
  case "$schema" in brain/Decision|brain/Reference|brain/Preference) ;; *) return 1 ;; esac
  out="$(mktemp "${TMPDIR:-/tmp}/lastdb-live-locators.XXXXXX")"
  chmod 600 "$out" || {
    rm -f "$out"
    return 1
  }
  # One POST /v1/read. The secret item is keys_only, so the reply has no secret text.
  payload="$(jq -nc --arg b "$LASTDB_LIVE_BRAIN_SLUG" --arg s "$LASTDB_LIVE_SECRET_SLUG" --arg schema "$schema" \
    '{reads:[
      {schema:$schema, key:{hash:$b}, limit:1},
      {schema:"lastsecrets/LastSecret", key:{hash:$s}, limit:1, keys_only:true}
    ]}')"
  if ! curl -fsS --max-time 30 --unix-socket "$PRIMARY_SOCK" \
      -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
      -H 'Content-Type: application/json' \
      --data "$payload" http://x/v1/read >"$out" 2>/dev/null; then
    rm -f "$out"
    return 1
  fi
  if ! jq -e --arg b "$LASTDB_LIVE_BRAIN_SLUG" --arg s "$LASTDB_LIVE_SECRET_SLUG" '
      (.results | type == "array" and length == 2)
      and all(.results[]; has("error") | not)
      and all(.results[]; .next_cursor == null)
      and (.results[0].records | type == "array" and length == 1)
      and .results[0].records[0].record.knowledge_record_slug == $b
      and ((.results[0].records[0].record.knowledge_record_title // "") | length) > 0
      and (.results[1] | has("records") | not)
      and (.results[1].keys | type == "array" and length == 1)
      and .results[1].keys[0].hash == $s
      and ((.results[1].keys[0].range == null) or (.results[1].keys[0].range == ""))
    ' "$out" >/dev/null 2>&1; then
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

classify_live_read_mode() {
  if [ "$SAFE_UPGRADE_APPS_OFF" != "1" ] && primary_board_read_ok; then
    LIVE_READ_MODE=board
    return 0
  fi
  if primary_brain_and_secret_ok; then
    LIVE_READ_MODE=brain
    return 0
  fi
  LIVE_READ_MODE=""
  return 1
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


# --- venue: the programs directory the LaunchAgent runs ----------------------

detect_live_venue() {
  # Sets: VENUE (programs), LIVE_BIN, OLD_PROGRAM_DIR, PROGRAMS_DIR.
  # The primary LaunchAgent runs one pair per full source commit under
  # $PRIMARY_HOME/native-run-v2-programs. The old directory never changes.
  VENUE=""
  LIVE_BIN=""
  [ -f "$LAUNCHD_PLIST" ] && OLD_PROGRAM_DIR="$(programs_old_dir_from_plist)" \
    || die "the primary LaunchAgent does not run a pair from $PRIMARY_HOME/native-run-v2-programs/<full commit>"
  VENUE="programs"
  PROGRAMS_DIR="$(dirname -- "$OLD_PROGRAM_DIR")"
  LIVE_BIN="$OLD_PROGRAM_DIR/lastdbd"
  log "live venue: programs"
  log "live binary: $LIVE_BIN"
  log "launchd label: $LAUNCHD_LABEL"
}

# This check is unconditional: the candidate pair is immutable.
assert_final_candidate_binding() {
  assert_candidate_binding_matches_expected \
    "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN" \
    "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" >/dev/null 2>&1 \
    || die "candidate pair changed before the live section; primary remains untouched"
}

# A live install that cannot name the real launchd job cannot restart
# the primary. Refuse rather than reload into the void — the old daemon keeps
# serving and every downstream health check passes, so this fails silent.
assert_launchd_label_usable() {
  [ "$VENUE" = "programs" ] || return 0
  case "$LAUNCHD_LABEL" in
    com.REPLACE.*)
      die "unresolved launchd label ($LAUNCHD_LABEL) — cannot restart primary. Set LASTDB_LAUNCHD_LABEL to the real job (see: launchctl list | grep lastdbd)" ;;
  esac
  if [ "$LAUNCHD_LABEL_RESOLVED" != "1" ]; then
    die "could not resolve the primary launchd label; refusing the live install"
  fi
  # A grep -q consumer can close the list pipe early and turn a loaded job
  # into a pipefail/SIGPIPE false negative. Query the exact GUI service.
  if ! lastdb_launchd_job_loaded launchctl "gui/$(id -u)/${LAUNCHD_LABEL}"; then
    die "launchd label $LAUNCHD_LABEL is not a loaded job — job reload would target the wrong service"
  fi
  if [ ! -f "$LAUNCHD_PLIST" ]; then
    die "primary LaunchAgent plist missing ($LAUNCHD_PLIST) for resolved label $LAUNCHD_LABEL"
  fi
  log "launchd label verified loaded: $LAUNCHD_LABEL"
}

# launchd SIGKILLs a job ExitTimeOut seconds after SIGTERM. The strict stop
# waits this long (plus its own bound) for the graceful flush; it never forces.
PRIMARY_EXIT_TIMEOUT_SECS="${LASTDB_PRIMARY_EXIT_TIMEOUT_SECS:-150}"

# The stop is valid only after this exact process reports a clean flush.
verify_old_primary_stopped() {
  local service="$1" receipt="$PRIMARY_HOME/.shutdown_flush_ready"
  local ledger="$PRIMARY_HOME/sessions.jsonl" session="$PRIMARY_HOME/current-session.json" ledger_size
  ! kill -0 "$OLD_PRIMARY_PID" 2>/dev/null \
    && ! lastdb_launchd_job_loaded launchctl "$service" \
    && ! live_unix_socket_has_listener "$PRIMARY_SOCK" \
    || die "old primary still runs or serves after the strict stop"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    || die "old primary did not write a safe shutdown flush receipt"
  jq -e --argjson pid "$OLD_PRIMARY_PID" --argjson start_ts "$OLD_PRIMARY_START_TS" '
    (keys | sort) == (["flush_ok","pid","start_ts","version"] | sort)
    and .version == 1 and .pid == $pid and .start_ts == $start_ts
    and .flush_ok == true
  ' "$receipt" >/dev/null || die "old primary flush receipt does not match the stopped session"
  # Mini records the flushed PID and boot identity in the receipt.
}

strict_prestop_old_primary() {
  local service="$1" program="$2" plist_program="" listener_pid="" out=""
  plist_program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD_PLIST" 2>/dev/null || true)"
  if [ "$VENUE" = programs ]; then
    plist_program="$(lastdb_programs_daemon_path "$PRIMARY_HOME" "$plist_program")" \
      || die "cannot resolve the primary plist program to its installed pair"
  fi
  [ "$plist_program" = "$program" ] \
    || die "primary plist program does not match the installed old daemon"
  [ ! -e "$PRIMARY_HOME/.shutdown_flush_ready" ] \
    && [ ! -L "$PRIMARY_HOME/.shutdown_flush_ready" ] \
    || die "a stale shutdown flush receipt exists before the stop"
  OLD_PRIMARY_PID="$(lastdb_launchd_job_pid launchctl "$service")"
  listener_pid="$(live_unix_socket_listener_pid "$PRIMARY_SOCK" || true)"
  [ -n "$OLD_PRIMARY_PID" ] && [ "$OLD_PRIMARY_PID" = "$listener_pid" ] \
    && live_unix_socket_is_healthy "$PRIMARY_SOCK" \
    || die "old primary is not supervised and healthy before the stop"
  OLD_PRIMARY_START_TS="$(native_primary_identity "$OLD_PRIMARY_PID" "$CURRENT_VER")" \
    || die "native primary boot identity differs before the stop"
  native_check_program_consumer "$program" "$service" "$OLD_PRIMARY_PID" \
    || die "the old native daemon has a different or additional executable consumer"
  OLD_PRIMARY_PS_LSTART="$(ps -p "$OLD_PRIMARY_PID" -o lstart= 2>/dev/null)" \
    || die "old primary process start time is unreadable before the stop"
  [ -n "$OLD_PRIMARY_PS_LSTART" ] \
    || die "old primary process start time is absent before the stop"
  write_cutover_recovery_state "${VENUE}-stop-started" true
  NATIVE_STOP_ARMED=1
  out="$(lastdb_launchd_graceful_prestop launchctl "$service" "$program" \
    "${LASTDB_PRIMARY_GRACEFUL_STOP_WAIT_SECS:-300}" \
    "$PRIMARY_EXIT_TIMEOUT_SECS" 1 2>&1)" \
    || die "strict old-primary stop failed: $out"
  log "$out"
  case "$out" in
    *'LASTDB_LAUNCHD_PRESTOP=ok '*"pid=$OLD_PRIMARY_PID "*'forced_kill=0'*) ;;
    *) die "strict old-primary stop did not prove a clean exit" ;;
  esac
  verify_old_primary_stopped "$service"
  write_cutover_recovery_state "${VENUE}-stopped" true
}

# Version parity cannot detect replacement bytes that report the same version.
# Every installed copy must match the immutable Loom hashes.
sidebin_pair_hashes_match_expected() {
  local daemon="$1" cli="$2" phase="$3"
  local expected_daemon="${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}"
  local expected_cli="${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}"
  local actual_daemon actual_cli failed=0

  case "$expected_daemon" in ''|*[!0-9a-f]*) failed=1 ;; esac
  case "$expected_cli" in ''|*[!0-9a-f]*) failed=1 ;; esac
  [ "${#expected_daemon}" -eq 64 ] || failed=1
  [ "${#expected_cli}" -eq 64 ] || failed=1
  if [ "$failed" -ne 0 ]; then
    printf 'RED: %s has an invalid expected SHA-256 binding\n' "$phase"
    return 1
  fi

  [ -f "$daemon" ] && [ ! -L "$daemon" ] && [ -x "$daemon" ] \
    || { printf 'RED: %s lastdbd is absent, linked, or not executable\n' "$phase"; failed=1; }
  [ -f "$cli" ] && [ ! -L "$cli" ] && [ -x "$cli" ] \
    || { printf 'RED: %s lastdb is absent, linked, or not executable\n' "$phase"; failed=1; }
  [ "$failed" -eq 0 ] || return 1

  actual_daemon="$(binding_sha256_file "$daemon" || true)"
  actual_cli="$(binding_sha256_file "$cli" || true)"
  [ "$actual_daemon" = "$expected_daemon" ] \
    || { printf 'RED: %s lastdbd bytes differ from the exact candidate\n' "$phase"; failed=1; }
  [ "$actual_cli" = "$expected_cli" ] \
    || { printf 'RED: %s lastdb bytes differ from the exact candidate\n' "$phase"; failed=1; }
  [ "$failed" -eq 0 ]
}

# --live-read-check: the Loom VERIFY step. One keyed live read, no lock, no write.
if [ "$LIVE_READ_CHECK" -eq 1 ]; then
  classify_live_read_mode || die "live read failed: Board did not answer and the brain plus LastSecrets locators are missing or unreadable"
  echo "LIVE_READ=$LIVE_READ_MODE"
  exit 0
fi

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

native_primary_route \
  || die "the primary home is not a native format 15 or newer home; this skill upgrades only those homes"
CURRENT_VER="$(native_socket_get /api/system/boot-identity | jq -er .build)" \
  || die "native primary build is unavailable"
log "current lastdbd: $CURRENT_VER"
log "primary home:    $PRIMARY_HOME (read only; never copied)"

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

# The trials boot generated nodes with Unix sockets under WORK. Darwin TMPDIR
# under /var/folders/... and routinesd scratch paths are too long for a
# 103-byte sockaddr_un, so the base is /tmp unless TMPDIR is already short and
# outside HOME.
_work_tmp="${TMPDIR:-/tmp}"
case "$(cd "$_work_tmp" 2>/dev/null && pwd -P || printf '%s' "$_work_tmp")" in
  "$_home_real"|"$_home_real"/*) _work_tmp="/tmp" ;;
esac
if [ "${#_work_tmp}" -gt 12 ]; then
  _work_tmp="/tmp"
fi
WORK="$(mktemp -d "${_work_tmp}/lastdb-safe-upgrade.XXXXXX")"
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

# A live Loom run must preserve the exact pair tuple from graph kickoff. Probe-
# only use stays available outside Loom and does not authorize a live change.
if [ "$PROBE_ONLY" -eq 0 ]; then
  BINDING_OUT=""
  set +e
  BINDING_OUT="$(assert_candidate_binding_matches_expected \
    "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN" \
    "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" 2>&1)"
  BINDING_RC=$?
  set -e
  if [ "$BINDING_RC" -ne 0 ]; then
    echo "VERDICT: RED"
    echo "REASON: candidate pair does not match the immutable Loom execution tuple"
    exit 1
  fi
  log "candidate binding GREEN: exact source, paths, versions, and binary hashes match Loom"
fi

if [ "$CAND_VER" = "$CURRENT_VER" ] && [ "$PROBE_ONLY" -eq 0 ]; then
  log "candidate matches current; no upgrade needed"
  echo "VERDICT: ALREADY_CURRENT"
  exit 0
fi

run_native_primary
exit 0
