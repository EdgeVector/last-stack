#!/usr/bin/env bash
# Build one synthetic LastDB home for the lastdb-safe-upgrade probes.
#
# WHY: the probes used to clone the primary home for every bar. The primary is
# multi-GB with hundreds of thousands of files, so one clone took minutes and
# the pair of booted daemons pushed the laptop into swap. A probe needs data
# that the BASELINE daemon wrote, not Tom's data. The candidate must read what
# the installed daemon wrote, so the baseline writes the seed here. The seed is
# small, so every probe copy is an instant APFS clone of it.
#
# WHAT IT WRITES: a home with Tom's identity.key (copied, never printed), the
# brain and lastsecrets schemas registered by the apps' own init commands, and
# in one batch: one keyed brain/Reference point record, M brain records,
# N brain/TagMembership rows under one hash (--cards; the range read), and four
# lastsecrets/LastSecret locators with fixed public test envelopes. Kanban is
# off (Tom, 2026-10-31), so the seed does not use it. The brain and lastsecrets
# CLIs get their own HOME (cli-home) so they never read or write the real
# ~/.brain or ~/.lastsecrets.
#
# It never starts a daemon on the primary home and never writes to it. It reads
# only <primary>/identity.key and <primary>/.bootstrap_done.
#
# Usage:
#   build-synthetic-home.sh --baseline-bin PATH --identity-from PRIMARY_HOME \
#     --out NEW_DIR [--cards N] [--records N] [--key KEY] [--live-env-plist FILE]
#
# Output dir layout:
#   NEW_DIR/home        node home (data dir for the probe daemons)
#   NEW_DIR/cli-home    HOME for brain and lastsecrets calls
#   NEW_DIR/seed.meta   key=value facts, written last
#   NEW_DIR/.complete   written after seed.meta; a seed without it is unusable
#
# Exit: 0 = complete seed; 1 = failed (owned container and evidence kept); 2 = usage.
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=live-lastdb-env.sh
. "$SCRIPT_DIR/live-lastdb-env.sh"
# shellcheck source=probe-copy-guards.sh
. "$SCRIPT_DIR/probe-copy-guards.sh"
# shellcheck source=deadline.sh
. "$SCRIPT_DIR/deadline.sh"
# shellcheck source=synthetic-home-checks.sh
. "$SCRIPT_DIR/synthetic-home-checks.sh"

BASELINE_BIN=""
IDENTITY_FROM=""
OUT=""
CARDS="$SYNTH_DEFAULT_CARDS"
RECORDS="$SYNTH_DEFAULT_RECORDS"
SEED_KEY=""
LIVE_PLIST="${LASTDB_LAUNCHD_PLIST:-}"
INIT_DEADLINE_SECS="${LASTDB_SYNTHETIC_INIT_DEADLINE_SECS:-600}"
BOOT_WAIT_SECS="${LASTDB_SYNTHETIC_BOOT_WAIT_SECS:-300}"
STOP_WAIT_SECS="${LASTDB_SYNTHETIC_STOP_WAIT_SECS:-240}"
EVIDENCE_ROOT="${LASTDB_SYNTHETIC_EVIDENCE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/lastdb-safe-upgrade/synthetic-build-failures}"

usage() {
  sed -n '2,34p' "$0"
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline-bin) BASELINE_BIN="${2:-}"; shift 2 ;;
    --identity-from) IDENTITY_FROM="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --cards) CARDS="${2:-}"; shift 2 ;;
    --records) RECORDS="${2:-}"; shift 2 ;;
    --key) SEED_KEY="${2:-}"; shift 2 ;;
    --live-env-plist) LIVE_PLIST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[synthetic-home] %s\n' "$*"; }
# Name the phase that starts now and log how long the previous one took.
PHASE_NAME=""
PHASE_AT=$SECONDS
phase() {
  [ -z "$PHASE_NAME" ] || log "phase $PHASE_NAME took $((SECONDS - PHASE_AT))s"
  PHASE_NAME="${1:-}"
  PHASE_AT=$SECONDS
}
FAIL_REASON=""
fail() { FAIL_REASON="$*"; printf '[synthetic-home] RED: %s\n' "$*" >&2; exit 1; }

[ -n "$BASELINE_BIN" ] && [ -x "$BASELINE_BIN" ] || { echo "--baseline-bin must be an executable" >&2; exit 2; }
[ -n "$IDENTITY_FROM" ] && [ -d "$IDENTITY_FROM" ] || { echo "--identity-from must be a home directory" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
synth_count_valid "$CARDS" || { echo "--cards must be a positive integer" >&2; exit 2; }
synth_count_valid "$RECORDS" || { echo "--records must be a positive integer" >&2; exit 2; }
[ -f "$IDENTITY_FROM/identity.key" ] && [ ! -L "$IDENTITY_FROM/identity.key" ] \
  || { echo "primary identity.key is absent or a symlink" >&2; exit 2; }
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "--out must not exist: $OUT" >&2; exit 2; }
# The seed must never live inside the primary, and the primary never inside it.
probe_copy_is_not_primary "$OUT" "$IDENTITY_FROM" || { echo "--out overlaps the primary home" >&2; exit 2; }

HOME_DIR="$OUT/home"
CLI_HOME="$OUT/cli-home"
BUILD="$OUT/.build"
SOCK="$HOME_DIR/data/folddb.sock"
[ "$(LC_ALL=C printf '%s' "$SOCK" | wc -c | tr -d ' ')" -le 103 ] \
  || { echo "synthetic owner socket path exceeds the native macOS bound" >&2; exit 2; }
BOOT_LOG="$BUILD/boot.log"
NODE_PID=""
NODE_PS_START=""
NODE_REAPED=1
NODE_START_TS=""
STOPPED_PID=""
STOPPED_START_TS=""
KNOWN_KEYS_VERIFIED=0
SHUTDOWN_FLUSH_VERIFIED=0
OUT_CREATED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$NODE_PID" ]; then stop_baseline || rc=1; fi
  if [ "$OUT_CREATED" -eq 1 ]; then
    save_evidence || rc=1
    # Keep the exact owned container until its public closeout is preserved
    # and all PROBE/CUTOVER/recovery consumers close. No cache-wide deletion.
    [ "$rc" -eq 0 ] || log "owned build retained for supported cleanup: $OUT" >&2
  fi
  exit "$rc"
}

# Keep bounded private tails. Only public-closeout.json is public evidence.
save_evidence() {
  local dir stamp f
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$EVIDENCE_ROOT/$stamp-$$"
  [ "$OUT_CREATED" -eq 1 ] || return 0
  mkdir -p "$EVIDENCE_ROOT" || return 1
  dir="$(mktemp -d "$EVIDENCE_ROOT/seed-closeout-$stamp.XXXXXX")" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  jq -n --arg container "$OUT" --arg key "$SEED_KEY" \
    --argjson uid "$(id -u)" --argjson keys "$KNOWN_KEYS_VERIFIED" \
    --argjson flushed "$SHUTDOWN_FLUSH_VERIFIED" --argjson reaped "$NODE_REAPED" \
    '{version:1,container:$container,key:$key,owner_uid:$uid,
      known_keys_verified:($keys == 1),shutdown_flush_verified:($flushed == 1),
      owned_child_reaped:($reaped == 1),consumer_release_required:true}' >"$dir/public-closeout.json" || return 1
  # Private diagnostic text cannot grow the retained proof without a bound.
  printf 'reason=%s\n' "${FAIL_REASON:-none}" | head -c 4096 >"$dir/reason.txt" || true
  for f in "$BUILD"/*.log "$BUILD"/*.out "$BUILD"/*.err; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    tail -c 65536 "$f" 2>/dev/null | tail -n 200 >"$dir/$(basename "$f")" || true
  done
  log "failure evidence: $dir" >&2
}
trap cleanup EXIT

umask 077
mkdir -m 700 "$OUT"
OUT_CREATED=1
mkdir -m 700 "$HOME_DIR" "$CLI_HOME" "$BUILD" "$CLI_HOME/.lastsecrets" "$CLI_HOME/.brain"
printf 'version=1\nowner_uid=%s\ncreator_pid=%s\n' "$(id -u)" "$$" >"$OUT/owner.meta"
jq -n --argjson uid "$(id -u)" --argjson dev "$(stat -f %d "$OUT")" \
  --argjson ino "$(stat -f %i "$OUT")" --argjson pid "$$" \
  '{version:1,kind:"synthetic-seed",owner_uid:$uid,device:$dev,inode:$ino,creator_pid:$pid}' \
  >"$OUT/.synthetic-seed-owner.json"

# Copy only the identity (and the bootstrap marker). Never log the key.
cp -p "$IDENTITY_FROM/identity.key" "$HOME_DIR/identity.key"
chmod 600 "$HOME_DIR/identity.key"
if [ -f "$IDENTITY_FROM/.bootstrap_done" ] && [ ! -L "$IDENTITY_FROM/.bootstrap_done" ]; then
  cp -p "$IDENTITY_FROM/.bootstrap_done" "$HOME_DIR/.bootstrap_done"
else
  printf 'ok\n' >"$HOME_DIR/.bootstrap_done"
fi

BASELINE_VERSION="$("$BASELINE_BIN" --version 2>/dev/null | awk '{print $NF}' || true)"
[ -n "$BASELINE_VERSION" ] || fail "baseline --version failed"
log "baseline $BASELINE_VERSION writes the seed: cards=$CARDS records=$RECORDS out=$OUT"

# --- boot the baseline daemon on the seed home ------------------------------
# The baseline writes under the live flags, minus the keys in
# SYNTH_WRITE_OMIT_KEYS (resident write mode wedges its persist lanes on a fresh
# home; see synthetic-home-checks.sh). Layout flags stay.
env_pairs=()
while IFS= read -r line; do
  [ -n "$line" ] && env_pairs+=("$line")
done <<EOF_ENV
$(live_lastdb_env_pairs "$LIVE_PLIST" | synth_filter_write_env)
EOF_ENV
if [ "${#env_pairs[@]}" -gt 0 ]; then
  log "mirroring live env keys: $(printf '%s\n' "${env_pairs[@]}" | cut -d= -f1 | tr '\n' ' ')"
fi
log "omitted while writing the seed: $SYNTH_WRITE_OMIT_KEYS"

# Start the baseline on HOME_DIR with the live tuning flags, minus the omitted
# keys. The seed must be written under the layout flags the primary runs,
# because they set the on-disk format. Sets NODE_PID once the identity answers.
boot_baseline() {
  local label="$1" uh="" i=0
  rm -f "$HOME_DIR"/data/*.sock
  env -u SENTRY_DSN -u FOLD_SENTRY_DSN -u OBS_SENTRY_DSN \
    -u LASTDB_HOME -u LASTDB_DATA_DIR \
    -u LASTDB_BUILD_CONFLICT_STAMP_ON_COPY -u MIMALLOC_PURGE_DELAY \
    ${env_pairs[@]+"${env_pairs[@]}"} \
    "$BASELINE_BIN" --data-dir "$HOME_DIR" >>"$BOOT_LOG" 2>&1 &
  NODE_PID=$!
  NODE_REAPED=0
  NODE_PS_START="$(ps -p "$NODE_PID" -o lstart=)" || fail "owned baseline start identity unavailable"
  while [ "$i" -lt "$BOOT_WAIT_SECS" ]; do
    i=$((i + 1))
    kill -0 "$NODE_PID" 2>/dev/null || fail "baseline exited during $label boot; private evidence retained"
    if [ -S "$SOCK" ]; then
      uh="$(curl -sS --max-time 3 --unix-socket "$SOCK" -H 'Host: localhost' \
        -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/system/auto-identity 2>/dev/null \
        | jq -r '.user_hash // empty' 2>/dev/null || true)"
      [ -n "$uh" ] && break
    fi
    sleep 1
  done
  [ -n "$uh" ] || fail "baseline identity not ready in ${BOOT_WAIT_SECS}s ($label boot)"
  NODE_START_TS="$(jq -er --argjson pid "$NODE_PID" '
    select(.pid == $pid and (.start_ts | type) == "number" and .start_ts > 0) | .start_ts
  ' "$HOME_DIR/current-session.json")" || fail "owned baseline session identity unavailable"
  [ ! -e "$HOME_DIR/.shutdown_flush_ready" ] && [ ! -L "$HOME_DIR/.shutdown_flush_ready" ] \
    || fail "owned baseline retains a stale shutdown receipt"
  log "baseline identity ready after ${i}s ($label boot)"
}

# Stop with SIGTERM and wait for the exit. A forced kill would leave a store
# that is not flushed, so a slow stop fails the build instead.
owned_baseline_alive() {
  local current command state
  kill -0 "$NODE_PID" 2>/dev/null || return 1
  state="$(ps -p "$NODE_PID" -o stat= 2>/dev/null)" || return 1
  case "$state" in Z*) return 1 ;; esac
  current="$(ps -p "$NODE_PID" -o lstart= 2>/dev/null)" || return 1
  [ "$current" = "$NODE_PS_START" ] || return 1
  command="$(ps -ww -p "$NODE_PID" -o command= 2>/dev/null)" || return 1
  case " $command " in *" --data-dir $HOME_DIR "*) return 0 ;; *) return 1 ;; esac
}

stop_baseline() {
  local i=0 rc=0 state pid="$NODE_PID" start="$NODE_START_TS" receipt="$HOME_DIR/.shutdown_flush_ready"
  [ -n "$pid" ] || return 0
  SHUTDOWN_FLUSH_VERIFIED=0
  if kill -0 "$pid" 2>/dev/null; then
    owned_baseline_alive || return 1
    kill -TERM "$pid" || return 1
    while owned_baseline_alive; do
      i=$((i + 1))
      if [ "$i" -gt "$STOP_WAIT_SECS" ]; then
        owned_baseline_alive && kill -KILL "$pid" || true
        rc=1
        sleep 2
        break
      fi
      sleep 1
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    state="$(ps -p "$pid" -o stat= 2>/dev/null)" || return 1
    case "$state" in Z*) ;; *) return 1 ;; esac
  fi
  wait "$pid" || rc=1
  NODE_PID=""
  NODE_REAPED=1
  [ "$rc" -eq 0 ] && [ -n "$start" ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  jq -e --argjson pid "$pid" --argjson start "$start" '
    (keys | sort) == (["flush_ok","pid","start_ts","version"] | sort)
    and .version == 1 and .pid == $pid and .start_ts == $start and .flush_ok == true
  ' "$receipt" >/dev/null || return 1
  [ -f "$HOME_DIR/sessions.jsonl" ] && [ ! -L "$HOME_DIR/sessions.jsonl" ] || return 1
  jq -se --argjson pid "$pid" --argjson start "$start" '
    ([.[] | select(.pid == $pid and .start_ts == $start)] | length) == 1
    and all(.[] | select(.pid == $pid and .start_ts == $start);
      .exit == "clean" and (.end_ts | type) == "number" and .end_ts >= $start)
  ' "$HOME_DIR/sessions.jsonl" >/dev/null || return 1
  SHUTDOWN_FLUSH_VERIFIED=1
  STOPPED_PID="$pid"
  STOPPED_START_TS="$start"
  log "owned baseline reaped with exact clean session and shutdown flush receipt"
}

phase first-boot
boot_baseline first

cli_env() {
  env HOME="$CLI_HOME" LASTDB_HOME="$HOME_DIR" \
    LASTSECRETS_CONFIG="$CLI_HOME/.lastsecrets/config.json" \
    BRAIN_CONFIG="$CLI_HOME/.brain/config.json" FBRAIN_CONFIG="$CLI_HOME/.brain/config.json" \
    FOLDDB_SOCKET_PATH="$SOCK" FBRAIN_FOLDDB_SOCKET="$SOCK" "$@"
}

# --- register the app schemas through the apps' own init ---------------------
# Mini resolves or registers each schema with the schema service, so this step
# needs the network. The seed is cached, so the cost is paid once per baseline.
phase lastsecrets-init
log "lastsecrets init"
rc=0
run_op_with_deadline "$INIT_DEADLINE_SECS" cli_env lastsecrets init \
  --config "$CLI_HOME/.lastsecrets/config.json" --socket "$SOCK" \
  >"$BUILD/lastsecrets-init.out" 2>"$BUILD/lastsecrets-init.err" || rc=$?
[ "$rc" -eq 0 ] || fail "lastsecrets init failed (rc=$rc); private evidence retained"
phase brain-init
log "brain init"
rc=0
run_op_with_deadline "$INIT_DEADLINE_SECS" cli_env brain init \
  --node-url http://127.0.0.1 --name synthetic --yes >"$BUILD/brain-init.out" 2>"$BUILD/brain-init.err" || rc=$?
[ "$rc" -eq 0 ] || fail "brain init failed (rc=$rc); private evidence retained"

# Collect the complete seed before one native durable mutation batch.
# The separate Python helper uses only the owned seed socket and the canonical
# schema identities returned by normal app initialization.
BATCH_HELPER="$SCRIPT_DIR/synthetic-record-batch.py"
[ -f "$BATCH_HELPER" ] || fail "synthetic batch helper unavailable"
phase seed-batch
if ! python3 "$BATCH_HELPER" write --home "$HOME_DIR" --cli-home "$CLI_HOME" \
    --primary-home "$IDENTITY_FROM" --cards "$CARDS" --records "$RECORDS" \
    >"$BUILD/batch-write.out" 2>"$BUILD/batch-write.err"; then
  fail "whole synthetic batch refused; no automatic retry"
fi

phase stop-after-writes
stop_baseline || fail "owned baseline did not prove a clean flush and exit after the batch"
phase verify-boot
boot_baseline verify
phase known-key-verification
if ! python3 "$BATCH_HELPER" verify --home "$HOME_DIR" --cli-home "$CLI_HOME" \
    --primary-home "$IDENTITY_FROM" --cards "$CARDS" --records "$RECORDS" \
    >"$BUILD/batch-verify.out" 2>"$BUILD/batch-verify.err"; then
  fail "rebooted seed exact known-key verification refused"
fi
KNOWN_KEYS_VERIFIED=1
phase final-stop
stop_baseline || fail "owned baseline did not prove the final clean flush and exit"
phase finish

rm -f "$HOME_DIR"/data/*.sock
probe_strip_cloud_state "$HOME_DIR" "$IDENTITY_FROM" || fail "cloud state could not be removed from the seed"
[ -f "$HOME_DIR/data/.device_id" ] || { uuidgen | tr 'A-Z' 'a-z' >"$HOME_DIR/data/.device_id"; }
[ -d "$HOME_DIR/data" ] || fail "seed has no data dir"

{
  printf 'key=%s\n' "$SEED_KEY"
  printf 'generator=%s\n' "$SYNTH_GENERATOR_VERSION"
  printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'baseline_version=%s\n' "$BASELINE_VERSION"
  printf 'baseline_sha256=%s\n' "$(synth_sha256_file "$BASELINE_BIN")"
  printf 'cards=%s\n' "$CARDS"
  printf 'records=%s\n' "$RECORDS"
  printf 'range_rows=%s\nsecrets=4\n' "$CARDS"
  printf 'known_keys_verified=true\nshutdown_flush_verified=true\n'
  printf 'owner_uid=%s\ncreator_pid=%s\n' "$(id -u)" "$$"
  printf 'write_env_omitted=%s\n' "$SYNTH_WRITE_OMIT_KEYS"
} >"$OUT/seed.meta"
python3 "$BATCH_HELPER" commit --home "$HOME_DIR" --cli-home "$CLI_HOME" \
  --primary-home "$IDENTITY_FROM" --cards "$CARDS" --records "$RECORDS" \
  --pid "$STOPPED_PID" --start-ts "$STOPPED_START_TS" \
  >"$BUILD/batch-commit.out" 2>"$BUILD/batch-commit.err" \
  || fail "owned seed completion commit refused"
phase ""
log "seed complete: $OUT ($(du -sh "$OUT" 2>/dev/null | awk '{print $1}')) in ${SECONDS}s"
