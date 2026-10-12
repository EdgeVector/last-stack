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
# kanban and brain schemas registered by the apps' own init commands, one
# milestone, N cards in todo/backlog/done, and M brain records. The kanban and
# brain CLIs get their own HOME (cli-home) so they never read or write the real
# ~/.fkanban or ~/.brain. The seed pins different schema hashes from the
# primary, so the probes must read it through this cli-home.
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
#   NEW_DIR/cli-home    HOME for kanban and brain calls
#   NEW_DIR/seed.meta   key=value facts, written last
#   NEW_DIR/.complete   written after seed.meta; a seed without it is unusable
#
# Exit: 0 = complete seed; 1 = failed (NEW_DIR removed, evidence kept); 2 = usage.
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
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
# Serial by default. Measured 2026-10-09 on lastdbd 0.23.3-2693 without resident
# write mode: 30 `kanban add` calls took 203 s one at a time and 199 s at 6-way
# parallel, and both left every row after a clean restart. Each write waits for a
# durable persist, so parallel callers gain nothing. (An earlier note blamed
# parallel writers for lost rows. The cause was resident write mode; see
# synthetic-home-checks.sh.)
CARD_PARALLEL="${LASTDB_SYNTHETIC_CARD_PARALLEL:-1}"
RECORD_PARALLEL="${LASTDB_SYNTHETIC_RECORD_PARALLEL:-1}"
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
BOOT_LOG="$BUILD/boot.log"
NODE_PID=""

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$NODE_PID" ] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill "$NODE_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    save_evidence || true
    rm -rf "$OUT"
  else
    rm -rf "$BUILD"
  fi
  exit "$rc"
}

# Keep bounded tails only. The logs hold no key material, but they stay small.
save_evidence() {
  local dir stamp f
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$EVIDENCE_ROOT/$stamp-$$"
  [ -d "$BUILD" ] || return 0
  mkdir -p "$dir" || return 0
  chmod 700 "$dir" 2>/dev/null || true
  printf 'reason=%s\n' "${FAIL_REASON:-unknown}" >"$dir/reason.txt"
  for f in "$BUILD"/*.log "$BUILD"/*.out "$BUILD"/*.err; do
    [ -f "$f" ] || continue
    tail -n 200 "$f" >"$dir/$(basename "$f")" 2>/dev/null || true
  done
  log "failure evidence: $dir" >&2
}
trap cleanup EXIT

umask 077
mkdir -m 700 "$OUT" "$HOME_DIR" "$CLI_HOME" "$BUILD"

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
    -u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_DATA_DIR \
    -u LASTDB_BUILD_CONFLICT_STAMP_ON_COPY -u MIMALLOC_PURGE_DELAY \
    ${env_pairs[@]+"${env_pairs[@]}"} \
    "$BASELINE_BIN" --data-dir "$HOME_DIR" >>"$BOOT_LOG" 2>&1 &
  NODE_PID=$!
  while [ "$i" -lt "$BOOT_WAIT_SECS" ]; do
    i=$((i + 1))
    kill -0 "$NODE_PID" 2>/dev/null || fail "baseline exited during $label boot ($(tail -2 "$BOOT_LOG" 2>/dev/null | tr '\n' ' '))"
    if [ -S "$SOCK" ]; then
      uh="$(curl -sS --max-time 3 --unix-socket "$SOCK" -H 'Host: localhost' \
        -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/system/auto-identity 2>/dev/null \
        | jq -r '.user_hash // empty' 2>/dev/null || true)"
      [ -n "$uh" ] && break
    fi
    sleep 1
  done
  [ -n "$uh" ] || fail "baseline identity not ready in ${BOOT_WAIT_SECS}s ($label boot)"
  log "baseline identity ready after ${i}s ($label boot)"
}

# Stop with SIGTERM and wait for the exit. A forced kill would leave a store
# that is not flushed, so a slow stop fails the build instead.
stop_baseline() {
  local i=0
  kill "$NODE_PID" 2>/dev/null || true
  while kill -0 "$NODE_PID" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le "$STOP_WAIT_SECS" ] || fail "baseline did not stop within ${STOP_WAIT_SECS}s; the seed would not be a flushed store"
    sleep 1
  done
  log "baseline stopped after ${i}s"
  NODE_PID=""
}

phase first-boot
boot_baseline first

cli_env() {
  env HOME="$CLI_HOME" LASTDB_HOME="$HOME_DIR" FOLDDB_HOME="$HOME_DIR" \
    FOLDDB_SOCKET_PATH="$SOCK" FBRAIN_FOLDDB_SOCKET="$SOCK" "$@"
}

# --- register the app schemas through the apps' own init ---------------------
# Mini resolves or registers each schema with the schema service, so this step
# needs the network. The seed is cached, so the cost is paid once per baseline.
phase kanban-init
log "kanban init"
rc=0
run_op_with_deadline "$INIT_DEADLINE_SECS" cli_env kanban init \
  --node-socket-path "$SOCK" --name synthetic >"$BUILD/kanban-init.out" 2>"$BUILD/kanban-init.err" || rc=$?
[ "$rc" -eq 0 ] || fail "kanban init failed (rc=$rc): $(tail -3 "$BUILD/kanban-init.err" 2>/dev/null | tr '\n' ' ')"
phase brain-init
log "brain init"
rc=0
run_op_with_deadline "$INIT_DEADLINE_SECS" cli_env brain init \
  --node-url http://127.0.0.1 --name synthetic --yes >"$BUILD/brain-init.out" 2>"$BUILD/brain-init.err" || rc=$?
[ "$rc" -eq 0 ] || fail "brain init failed (rc=$rc): $(tail -3 "$BUILD/brain-init.err" 2>/dev/null | tr '\n' ' ')"

# --- data --------------------------------------------------------------------
# One item per call, one at a time. The seed is a throwaway node, so this loop
# adds no load to the primary.
HELPER="$BUILD/item.sh"
cat >"$HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
# usage: item.sh card|record N   (env: CLI_HOME HOME_DIR SOCK)
set -u
kind="${1:?}"; n="${2:?}"
cli() {
  env HOME="$CLI_HOME" LASTDB_HOME="$HOME_DIR" FOLDDB_HOME="$HOME_DIR" \
    FOLDDB_SOCKET_PATH="$SOCK" FBRAIN_FOLDDB_SOCKET="$SOCK" "$@"
}
para() {
  # Deterministic filler, about 1 KB, varied by $1.
  local i=0 out=""
  while [ "$i" -lt 8 ]; do
    out="${out}Synthetic paragraph $1.$i: the safe-upgrade probe reads and rewrites this text to exercise the store with a realistic body size. Token $((($1 * 7919 + i * 104729) % 100003)).
"
    i=$((i + 1))
  done
  printf '%s' "$out"
}
case "$kind" in
  card)
    case $((n % 20)) in
      0|1|2|3|4|5|6|7|8|9|10|11) col=todo ;;
      12|13|14) col=backlog ;;
      *) col=done ;;
    esac
    body="$(printf '## GOAL\n\n%s\n## END STATE\n\n- Synthetic card %s reaches %s.\n' "$(para "$n")" "$n" "$col")"
    if printf '%s\n' "$body" | cli kanban add "synth-card-$n" --title "Synthetic card $n" \
        --column "$col" --kind pr --milestone synth-ms --repo EdgeVector/synthetic \
        --priority "P$((n % 4))" --tags "synthetic,lane-$((n % 7))" >/dev/null 2>&1; then
      echo "OK card $n $col"
    else
      echo "FAIL card $n $col"
    fi
    ;;
  record)
    case $((n % 4)) in
      0) type=reference ;;
      1) type=concept ;;
      2) type=preference ;;
      *) type=design ;;
    esac
    if printf -- '---\ntype: %s\nslug: synth-%s-%s\ntitle: Synthetic %s %s\n---\n%s\n' \
        "$type" "$type" "$n" "$type" "$n" "$(para "$n")" | cli brain put >/dev/null 2>&1; then
      echo "OK record $n $type"
    else
      echo "FAIL record $n $type"
    fi
    ;;
  *) echo "FAIL unknown $kind $n"; exit 2 ;;
esac
EOF_HELPER
chmod 700 "$HELPER"
export CLI_HOME HOME_DIR SOCK

phase milestone
log "milestone"
rc=0
printf '## GOAL\n\nSynthetic milestone for probes.\n\n## END STATE\n\n- Cards exist.\n' \
  | run_op_with_deadline 120 cli_env kanban milestone add synth-ms --title "Synthetic milestone" --state active \
    >"$BUILD/milestone.out" 2>"$BUILD/milestone.err" || rc=$?
[ "$rc" -eq 0 ] || fail "milestone add failed (rc=$rc): $(tail -3 "$BUILD/milestone.err" 2>/dev/null | tr '\n' ' ')"

phase cards
log "cards: $CARDS (parallel $CARD_PARALLEL)"
seq 1 "$CARDS" | xargs -P "$CARD_PARALLEL" -n 1 bash "$HELPER" card >"$BUILD/cards.log" 2>/dev/null || true
cards_ok="$(grep -c '^OK card ' "$BUILD/cards.log" || true)"
phase records
log "records: $RECORDS (parallel $RECORD_PARALLEL)"
seq 1 "$RECORDS" | xargs -P "$RECORD_PARALLEL" -n 1 bash "$HELPER" record >"$BUILD/records.log" 2>/dev/null || true
records_ok="$(grep -c '^OK record ' "$BUILD/records.log" || true)"
log "written: cards_ok=$cards_ok/$CARDS records_ok=$records_ok/$RECORDS"
synth_write_ratio_ok "$cards_ok" "$CARDS" 90 || fail "too few cards written ($cards_ok of $CARDS)"
synth_write_ratio_ok "$records_ok" "$RECORDS" 75 || fail "too few records written ($records_ok of $RECORDS)"

# --- flush, reboot, verify ---------------------------------------------------
# A running baseline under the live flags can list a stale view of rows it just
# wrote (measured 2026-10-09: 12 serial `kanban add` calls, `kanban list`
# showed 1, and a clean restart showed 12). So stop first, boot again, and
# judge the seed on the second boot. That is also the state the probes boot.
phase stop-after-writes
stop_baseline
phase verify-boot
boot_baseline verify

list_rc=0
cli_env kanban list --column todo --json >"$BUILD/list.out" 2>"$BUILD/list.err" || list_rc=$?
todo_total="$(jq -r '.total // (.cards | length) // 0' "$BUILD/list.out" 2>/dev/null || echo 0)"
case "$todo_total" in ''|*[!0-9]*) todo_total=0 ;; esac
todo_expected="$(synth_expected_todo "$CARDS")"
[ "$todo_total" -gt 0 ] \
  || fail "kanban list --column todo returns no cards on the rebooted seed (rc=$list_rc bytes=$(wc -c <"$BUILD/list.out" | tr -d ' ') err=$(head -c 200 "$BUILD/list.err" | tr '\n' ' '))"
synth_write_ratio_ok "$todo_total" "$todo_expected" 90 \
  || fail "rebooted seed lists $todo_total todo cards; expected about $todo_expected"
board_title="$(curl -sS --max-time 30 --unix-socket "$SOCK" -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' -H 'Content-Type: application/json' \
  --data '{"schema_name":"Board","fields":["title"],"filter":{"HashKey":"default"}}' http://x/api/query 2>/dev/null \
  | jq -r '.results[0].fields.title // empty' 2>/dev/null || true)"
[ -n "$board_title" ] || fail "Board/default has no title on the rebooted seed"
log "verified on reboot: todo cards=$todo_total (expected about $todo_expected), board title present"
phase final-stop
stop_baseline
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
  printf 'cards=%s\n' "$cards_ok"
  printf 'records=%s\n' "$records_ok"
  printf 'todo_cards=%s\n' "$todo_total"
  printf 'write_env_omitted=%s\n' "$SYNTH_WRITE_OMIT_KEYS"
} >"$OUT/seed.meta"
: >"$OUT/.complete"
phase ""
log "seed complete: $OUT ($(du -sh "$OUT" 2>/dev/null | awk '{print $1}')) in ${SECONDS}s"
