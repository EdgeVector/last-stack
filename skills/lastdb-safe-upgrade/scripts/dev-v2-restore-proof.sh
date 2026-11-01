#!/usr/bin/env bash
# Prove that one exact lastdb/lastdbd pair can back up a synthetic trial home to
# DEV with format 7 V2 backup and restore that exact commit into a source-free
# home. The format 7 V2 route uses this instead of dev-photograph-candidate-proof.sh,
# which needs the retired V1 connect/snapshot/restore commands and a
# laststore_high_water.json that a V2 home does not have.
#
# This helper never points a candidate at the live primary home and never
# copies it. It clones this run's trial home (a copy of the synthetic seed). The
# seed carries a copy of the primary identity.key, so the DEV account is the
# primary identity's DEV account, the same account the V1 photograph used.
#
# All steps use the exact candidate pair:
#   1. clone the trial home and boot the candidate on the clone (V2 enabled);
#   2. register a credentials-only DEV device for the seed identity
#      (`cloud recover-credentials-home`; the DEV account must already exist);
#   3. connect the clone to DEV (`backup-v2 connect --existing`), publish one
#      manual snapshot (`backup-v2 start`), and stop the clone strictly;
#   4. restore that exact commit from the DEV API key and the recovery phrase
#      only (`backup-v2 restore`), into a new home, with no source home;
#   5. require the restored home to be Cloud Off, boot it, read every known
#      seed key in one batch, and stop it strictly;
#   6. write receipt v5, bound to the Loom execution and the exact pair.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dev-photograph-stamp-gate.sh
. "$SCRIPT_DIR/dev-photograph-stamp-gate.sh"
# shellcheck source=live-lastdb-env.sh
. "$SCRIPT_DIR/live-lastdb-env.sh"

PHRASE_HELPER="$SCRIPT_DIR/dev-v2-recovery-phrase.py"
BATCH_HELPER="$SCRIPT_DIR/synthetic-record-batch.py"
EVIDENCE_SANITIZER="$SCRIPT_DIR/dev-photograph-sanitize-tail.py"
CANDIDATE_DAEMON=""
CANDIDATE_CLI=""
PRIMARY_HOME_ARG=""
CLONE_SOURCE=""
CLI_HOME=""
CARDS=""
RECORDS=""
RECEIPT=""
SOURCE_OID=""
LIVE_LASTDB_ENV_ARGS=()
PROOF_TMP_BASE=""
PROOF_ROOT_REAL=""
PROOF_SENTINEL=""
PROOF_TOKEN=""
PROOF_HOME=""
RESTORED_HOME=""
SOURCE_PID=""
RESTORED_PID=""
STARTED_PID=""
READY_START_TS=""
FAILURE_PHASE="preflight"
FAILURE_REASON="V2 DEV restore proof failed"
BACKUP_TIMEOUT="${LASTDB_DEV_V2_BACKUP_TIMEOUT_SECS:-900}"
RESTORE_TIMEOUT="${LASTDB_DEV_V2_RESTORE_TIMEOUT_SECS:-1800}"
CLI_TIMEOUT="${LASTDB_DEV_V2_CLI_TIMEOUT_SECS:-180}"
READY_WAITS="${LASTDB_DEV_V2_READY_WAITS:-300}"
STOP_WAITS="${LASTDB_DEV_V2_STOP_WAITS:-180}"

usage() {
  cat <<'EOF'
Usage: dev-v2-restore-proof.sh \
  --candidate-lastdbd PATH --candidate-lastdb PATH \
  --primary-home PATH --clone-source TRIAL_HOME --cli-home SEED_CLI_HOME \
  --cards N --records M --receipt PATH --source-git-oid OID

The immutable hashes, versions, paths, source OID, and Loom execution ID must
also exist in the LASTDB_SAFE_UPGRADE_EXPECTED_* and LOOM_EXEC_ID variables.
EOF
}

proof_die() {
  FAILURE_REASON="$1"
  printf 'DEV_V2_RESTORE: RED\n' >&2
  printf 'REASON: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-lastdbd) [ "$#" -ge 2 ] || proof_die "candidate daemon argument is incomplete"; CANDIDATE_DAEMON="$2"; shift 2 ;;
    --candidate-lastdb) [ "$#" -ge 2 ] || proof_die "candidate CLI argument is incomplete"; CANDIDATE_CLI="$2"; shift 2 ;;
    --primary-home) [ "$#" -ge 2 ] || proof_die "primary home argument is incomplete"; PRIMARY_HOME_ARG="$2"; shift 2 ;;
    --clone-source) [ "$#" -ge 2 ] || proof_die "clone source argument is incomplete"; CLONE_SOURCE="$2"; shift 2 ;;
    --cli-home) [ "$#" -ge 2 ] || proof_die "CLI home argument is incomplete"; CLI_HOME="$2"; shift 2 ;;
    --cards) [ "$#" -ge 2 ] || proof_die "cards argument is incomplete"; CARDS="$2"; shift 2 ;;
    --records) [ "$#" -ge 2 ] || proof_die "records argument is incomplete"; RECORDS="$2"; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || proof_die "receipt argument is incomplete"; RECEIPT="$2"; shift 2 ;;
    --source-git-oid) [ "$#" -ge 2 ] || proof_die "source OID argument is incomplete"; SOURCE_OID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) proof_die "unknown V2 DEV restore proof argument" ;;
  esac
done

[ -n "$CANDIDATE_DAEMON" ] || proof_die "candidate daemon is absent"
[ -n "$CANDIDATE_CLI" ] || proof_die "candidate CLI is absent"
[ -n "$PRIMARY_HOME_ARG" ] || proof_die "primary home is absent"
[ -n "$CLONE_SOURCE" ] || proof_die "the trial clone source is absent"
[ -n "$CLI_HOME" ] || proof_die "the seed CLI home is absent"
[ -n "$RECEIPT" ] || proof_die "receipt path is absent"
[ -n "$SOURCE_OID" ] || proof_die "source OID is absent"
case "$RECEIPT" in /*) ;; *) proof_die "receipt path is not absolute" ;; esac
for count in "$CARDS" "$RECORDS"; do
  case "$count" in ''|*[!0-9]*|0) proof_die "the seed card and record counts must be positive integers" ;; esac
  [ "$count" -le 64 ] || proof_die "the seed card and record counts must be 64 or less"
done
for limit in "$BACKUP_TIMEOUT" "$RESTORE_TIMEOUT" "$CLI_TIMEOUT" "$READY_WAITS" "$STOP_WAITS"; do
  case "$limit" in ''|*[!0-9]*|0) proof_die "a V2 DEV proof time limit is not a positive integer" ;; esac
done
for tool in jq python3 perl curl base64 uuidgen cmp; do
  command -v "$tool" >/dev/null 2>&1 || proof_die "$tool is unavailable"
done
for helper in "$PHRASE_HELPER" "$BATCH_HELPER"; do
  [ -f "$helper" ] && [ ! -L "$helper" ] || proof_die "a V2 DEV proof helper file is absent or unsafe"
done

while IFS= read -r env_pair; do
  [ -n "$env_pair" ] && LIVE_LASTDB_ENV_ARGS+=("$env_pair")
done <<EOF_ENV
$(live_lastdb_env_pairs "${LASTDB_LAUNCHD_PLIST:-}")
EOF_ENV
# The daemon and every CLI call get the primary's LASTDB_* tuning, V2 enabled,
# and no inherited home, device or error-report target.
CAND_ENV=(env -u LASTDB_HOME -u FOLDDB_HOME -u FOLD_SYNC_DEVICE_ID -u OBS_SENTRY_DSN
  ${LIVE_LASTDB_ENV_ARGS[@]+"${LIVE_LASTDB_ENV_ARGS[@]}"} LASTDB_BYTE_BACKUP_V2_ENABLED=true)

FAILURE_PHASE="candidate_binding"
assert_candidate_binding_matches_expected \
    "$CANDIDATE_DAEMON" "$CANDIDATE_CLI" "$SOURCE_OID" >/dev/null 2>&1 \
  || proof_die "the exact candidate binding changed before the V2 DEV proof"

FAILURE_PHASE="input_safety"
CANDIDATE_DAEMON="$(_dev_stamp_real_file "$CANDIDATE_DAEMON")"
CANDIDATE_CLI="$(_dev_stamp_real_file "$CANDIDATE_CLI")"
PRIMARY_HOME_ARG="$(_dev_stamp_real_dir "$PRIMARY_HOME_ARG")" \
  || proof_die "the primary home cannot resolve"
CLONE_SOURCE="$(_dev_stamp_real_dir "$CLONE_SOURCE")" \
  || proof_die "the trial clone source cannot resolve"
CLI_HOME="$(_dev_stamp_real_dir "$CLI_HOME")" \
  || proof_die "the seed CLI home cannot resolve"
[ -d "$PRIMARY_HOME_ARG/data" ] || proof_die "the primary data directory is absent"
[ -d "$CLONE_SOURCE/data" ] && [ ! -L "$CLONE_SOURCE/data" ] \
  && [ -f "$CLONE_SOURCE/identity.key" ] && [ ! -L "$CLONE_SOURCE/identity.key" ] \
  && [ -f "$CLONE_SOURCE/.safe-upgrade/complete" ] \
  && [ ! -L "$CLONE_SOURCE/.safe-upgrade/complete" ] \
  && grep -qx 'kind=trial' "$CLONE_SOURCE/.safe-upgrade/complete" \
  || proof_die "the trial clone source is absent or unsafe"
_dev_stamp_paths_do_not_overlap "$CLONE_SOURCE" "$PRIMARY_HOME_ARG" \
  || proof_die "the trial clone source overlaps the live primary"
_dev_stamp_paths_do_not_overlap "$CLI_HOME" "$PRIMARY_HOME_ARG" \
  || proof_die "the seed CLI home overlaps the live primary"
for name in .brain .lastsecrets; do
  [ -f "$CLI_HOME/$name/config.json" ] && [ ! -L "$CLI_HOME/$name/config.json" ] \
    || proof_die "the seed CLI home lacks a safe app config"
done

# A short real-path root. V2 opens every connection file with NOFOLLOW per path
# component, so a /tmp symlink fails as "native backup disk operation failed",
# and the restored socket path must stay under the native 103-byte cap.
PROOF_TMP_BASE="$(_dev_stamp_real_dir "${LASTDB_DEV_V2_PROOF_TMP_ROOT:-/tmp}")" \
  || proof_die "the V2 DEV proof temporary root cannot resolve"
case "$PROOF_TMP_BASE" in /|"") proof_die "the V2 DEV proof temporary root is unsafe" ;; esac
_dev_stamp_paths_do_not_overlap "$PROOF_TMP_BASE/dev-v2-placeholder" "$PRIMARY_HOME_ARG" \
  || proof_die "the V2 DEV proof temporary root overlaps the primary home"
socket_bytes="$(printf '%s' "$PROOF_TMP_BASE/lastdb-dev-v2-XXXXXX/restored/data/folddb-full.sock" | wc -c | tr -d ' ')"
[ "$socket_bytes" -le 103 ] || proof_die "the V2 DEV proof home exceeds the native socket path cap"
safe_exec_id="$(printf '%s' "${LOOM_EXEC_ID:-missing}" | tr -c 'A-Za-z0-9._-' '_')"

# The caller cannot redirect receipt output. The exact safe path derives from
# this Loom execution and both expected binary hashes, as for the photograph.
receipt_root="$(dev_stamp_receipt_root)"
case "$receipt_root" in /*) ;; *) proof_die "the DEV receipt root is not absolute" ;; esac
receipt_root_real="$(_dev_stamp_real_maybe_absent "$receipt_root")" \
  || proof_die "the DEV receipt root cannot resolve"
case "$receipt_root_real" in /|"") proof_die "the DEV receipt root is unsafe" ;; esac
[ ! -e "$receipt_root" ] || { [ -d "$receipt_root" ] && [ ! -L "$receipt_root" ]; } \
  || proof_die "the DEV receipt root is not a real directory"
_dev_stamp_paths_do_not_overlap "$receipt_root_real/receipt-placeholder" "$PRIMARY_HOME_ARG" \
  || proof_die "the DEV receipt root overlaps the live primary"
expected_receipt_name="${safe_exec_id}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:0:16}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:0:16}.receipt"
receipt_parent_real="$(_dev_stamp_real_maybe_absent "$(dirname -- "$RECEIPT")")" \
  || proof_die "the DEV receipt parent cannot resolve"
[ "$receipt_parent_real" = "$receipt_root_real" ] \
  && [ "$(basename -- "$RECEIPT")" = "$expected_receipt_name" ] \
  && [ ! -L "$RECEIPT" ] \
  || proof_die "the DEV receipt path is not bound to this execution and candidate pair"
RECEIPT="$receipt_root_real/$expected_receipt_name"

FAILURE_PHASE="proof_root"
proof_root="$(mktemp -d "$PROOF_TMP_BASE/lastdb-dev-v2-XXXXXX")" \
  || proof_die "the V2 DEV proof root cannot be created"
PROOF_ROOT_REAL="$(_dev_stamp_real_dir "$proof_root")" \
  || proof_die "the V2 DEV proof root cannot resolve"
chmod 700 "$PROOF_ROOT_REAL"
PROOF_SENTINEL="$PROOF_ROOT_REAL/.lastdb-dev-v2-owner"
PROOF_TOKEN="${LOOM_EXEC_ID:-missing}:$$:${PROOF_ROOT_REAL}"
(umask 077; printf '%s\n' "$PROOF_TOKEN" >"$PROOF_SENTINEL")
PROOF_HOME="$PROOF_ROOT_REAL/home"
RESTORED_HOME="$PROOF_ROOT_REAL/restored"
SOURCE_LOG="$PROOF_ROOT_REAL/source-daemon.log"
RESTORED_LOG="$PROOF_ROOT_REAL/restored-daemon.log"

proof_root_is_owned() {
  [ -n "$PROOF_ROOT_REAL" ] && [ -f "$PROOF_SENTINEL" ] && [ ! -L "$PROOF_SENTINEL" ] \
    && [ "$(cat "$PROOF_SENTINEL" 2>/dev/null || true)" = "$PROOF_TOKEN" ] || return 1
  case "$PROOF_ROOT_REAL" in "$PROOF_TMP_BASE"/lastdb-dev-v2-*) return 0 ;; esac
  return 1
}

# Bash reaps a background child as soon as it exits, so its PID can return to
# another process. Signal only a live PID whose argv names this candidate and
# this home. An empty argv (a sandbox hides it) is still this script's child.
candidate_is_owned() {
  local pid="$1" home="$2" command_line
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  [ -z "$command_line" ] && return 0
  case "$command_line" in *"$CANDIDATE_DAEMON"*"$home"*) return 0 ;; esac
  return 1
}

# Start in this shell (not in a command substitution) so the daemon is this
# script's own child.
start_candidate() {
  "${CAND_ENV[@]}" "$CANDIDATE_DAEMON" --data-dir "$1" >"$2" 2>&1 &
  STARTED_PID=$!
}

# Ready means the home's own socket names this exact PID.
wait_ready() {
  local pid="$1" home="$2" boot n=0
  boot="$PROOF_ROOT_REAL/boot-$pid.json"
  while [ "$n" -lt "$READY_WAITS" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -S "$home/data/folddb.sock" ] \
        && curl -fsS --max-time 10 --unix-socket "$home/data/folddb.sock" \
          -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
          http://x/api/system/boot-identity >"$boot" 2>/dev/null \
        && jq -e --argjson pid "$pid" \
          '.pid == $pid and (.process_start_ts | type == "number")' "$boot" >/dev/null 2>&1; then
      READY_START_TS="$(jq -r '.process_start_ts' "$boot")"
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  return 1
}

# A strict stop: SIGTERM only, then the exact flush receipt of that process.
strict_stop() {
  local pid="$1" start_ts="$2" home="$3" n=0
  candidate_is_owned "$pid" "$home" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$STOP_WAITS" ]; do
    sleep 1
    n=$((n + 1))
  done
  ! kill -0 "$pid" 2>/dev/null || return 1
  wait "$pid" 2>/dev/null || true
  [ -f "$home/.shutdown_flush_ready" ] && [ ! -L "$home/.shutdown_flush_ready" ] \
    && jq -e --argjson pid "$pid" --argjson ts "$start_ts" \
      '. == {"version": 1, "pid": $pid, "start_ts": $ts, "flush_ok": true}' \
      "$home/.shutdown_flush_ready" >/dev/null 2>&1
}

# Failure cleanup only. The proof has already failed, so a forced kill after
# the grace period is the lesser harm than a leaked daemon on a copied identity.
stop_on_failure() {
  local pid="$1" home="$2" n=0
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  candidate_is_owned "$pid" "$home" || return 1
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do
    sleep 1
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    candidate_is_owned "$pid" "$home" || return 1
    kill -KILL "$pid" 2>/dev/null || return 1
  fi
  wait "$pid" 2>/dev/null || true
  ! kill -0 "$pid" 2>/dev/null
}

# Run one command under a hard deadline. alarm(2) survives exec, so the timer
# binds the final program, and stdin stays the caller's pipe. Do not use
# run_op_with_deadline for a piped secret: it backgrounds the command, and bash
# gives a background command /dev/null as stdin when job control is off.
with_alarm() {
  local secs="$1"
  shift
  perl -e 'alarm(shift @ARGV); exec { $ARGV[0] } @ARGV; exit 127' "$secs" "$@"
}

# One candidate CLI call. stdout goes to <name>.json, stderr to <name>.err.
cand_cli() {
  local name="$1"
  shift
  with_alarm "$CLI_TIMEOUT" "${CAND_ENV[@]}" "$CANDIDATE_CLI" "$@" \
    >"$PROOF_ROOT_REAL/$name.json" 2>"$PROOF_ROOT_REAL/$name.err"
}

emit_failure_evidence() {
  local log
  printf 'DEV_V2_RESTORE_FAILURE phase=%s source_pid=%s restored_pid=%s reason=%s\n' \
    "$FAILURE_PHASE" "${SOURCE_PID:-none}" "${RESTORED_PID:-none}" "$FAILURE_REASON" >&2
  [ -f "$EVIDENCE_SANITIZER" ] && [ ! -L "$EVIDENCE_SANITIZER" ] || return 0
  for log in "$SOURCE_LOG" "$RESTORED_LOG" "$PROOF_ROOT_REAL"/*.err; do
    [ -f "$log" ] && [ -s "$log" ] || continue
    printf 'DEV_V2_RESTORE_TAIL_BEGIN %s\n' "$(basename -- "$log")" >&2
    python3 -I "$EVIDENCE_SANITIZER" --source "$log" --lines 30 --bytes 16384 >&2 2>/dev/null \
      || printf '<sanitizer-failed-closed>\n' >&2
    printf 'DEV_V2_RESTORE_TAIL_END\n' >&2
  done
}

cleanup_v2_proof() {
  local rc=$? stopped=1
  trap - EXIT HUP INT TERM
  set +e
  stop_on_failure "$SOURCE_PID" "$PROOF_HOME" || stopped=0
  stop_on_failure "$RESTORED_PID" "$RESTORED_HOME" || stopped=0
  [ "$rc" -eq 0 ] || emit_failure_evidence
  if [ "$stopped" -eq 1 ] && proof_root_is_owned; then
    # The root holds copies of the seed identity and a DEV API key.
    rm -rf -- "$PROOF_ROOT_REAL"
  elif [ -n "$PROOF_ROOT_REAL" ]; then
    printf 'DEV_V2_RESTORE_RETAINED: a candidate did not stop; remove the proof root after it stops\n' >&2
  fi
  exit "$rc"
}
trap cleanup_v2_proof EXIT
trap 'FAILURE_REASON="the V2 DEV proof received a signal"; exit 1' HUP INT TERM

FAILURE_PHASE="clone_trial"
if stat --version >/dev/null 2>&1; then
  cp -R "$CLONE_SOURCE" "$PROOF_HOME" >/dev/null 2>&1
else
  cp -cR "$CLONE_SOURCE" "$PROOF_HOME" >/dev/null 2>&1
fi || proof_die "the trial home cannot be cloned for the V2 DEV proof"
chmod 700 "$PROOF_HOME"
[ -d "$PROOF_HOME/data" ] && [ ! -L "$PROOF_HOME/data" ] \
  && [ -f "$PROOF_HOME/identity.key" ] && [ ! -L "$PROOF_HOME/identity.key" ] \
  || proof_die "the trial clone lacks a required durable file"
# The synthetic seed never had cloud state. Refuse a clone that carries some,
# so no copied credential or stream can reach DEV.
for rel in cloud_sync.json cloud_sync.json.paused .cloud_resume_required native_cloud_backup \
    cloud-byte-backup-v2-manual.json data/cloud-byte-backup-v2 \
    data/disk-run/cloud-byte-backup-v2 data/disk-run/cloud-byte-source-v2; do
  [ ! -e "$PROOF_HOME/$rel" ] && [ ! -L "$PROOF_HOME/$rel" ] \
    || proof_die "the trial clone carries cloud state ($rel); the synthetic seed must be Cloud Off"
done
rm -f -- "$PROOF_HOME/data/folddb.sock" "$PROOF_HOME/data/folddb-full.sock"
identity_before="$(dev_stamp_sha256_file "$PROOF_HOME/identity.key")" \
  || proof_die "the cloned identity cannot be read"

FAILURE_PHASE="source_boot"
start_candidate "$PROOF_HOME" "$SOURCE_LOG"
SOURCE_PID="$STARTED_PID"
wait_ready "$SOURCE_PID" "$PROOF_HOME" \
  || proof_die "the exact candidate did not serve the trial clone"
SOURCE_START_TS="$READY_START_TS"

FAILURE_PHASE="source_status"
cand_cli status0 --data-dir "$PROOF_HOME" cloud backup-v2 status --json \
  || proof_die "the exact candidate did not report V2 status on the trial clone"
user_hash="$(jq -er '.user_hash | select(type == "string" and test("^[0-9a-f]{32}$"))' \
  "$PROOF_ROOT_REAL/status0.json" 2>/dev/null)" \
  || proof_die "the trial clone has no valid user hash"

# The seed travels on stdin only. The command writes a credentials-only home
# with a paused DEV config and never opens a source home.
FAILURE_PHASE="dev_register"
mkdir -m 700 "$PROOF_ROOT_REAL/registration"
REG_HOME="$PROOF_ROOT_REAL/registration/home"
base64 <"$PROOF_HOME/identity.key" \
  | with_alarm "$CLI_TIMEOUT" "${CAND_ENV[@]}" "$CANDIDATE_CLI" cloud recover-credentials-home \
      --into "$REG_HOME" --env dev --expected-user-hash "$user_hash" --identity-seed-stdin --json \
      >"$PROOF_ROOT_REAL/register.json" 2>"$PROOF_ROOT_REAL/register.err" \
  || proof_die "the exact candidate could not register a DEV device for the seed identity; the DEV account must exist (SKILL.md: V2 DEV restore proof)"
jq -e --arg h "$user_hash" '
    .ok == true and .schema == "lastdb.credentials-recovery.v1"
    and .account_id == $h and .environment == "dev" and .credentials_only == true
    and .cloud_sync_off == true and .local_store_opened == false
    and .api_key_output == false and .identity_seed_output == false
  ' "$PROOF_ROOT_REAL/register.json" >/dev/null 2>&1 \
  || proof_die "the DEV registration report is not a credentials-only DEV device for this identity"
PAUSED_CONFIG="$REG_HOME/cloud_sync.json.paused"
[ -f "$PAUSED_CONFIG" ] && [ ! -L "$PAUSED_CONFIG" ] \
  && [ "$(_dev_stamp_file_mode "$PAUSED_CONFIG" || true)" = "600" ] \
  && jq -e --arg url "$LASTDB_DEV_BACKUP_API_URL_DEFAULT" '
    (keys | sort) == ["api_key","api_url"] and .api_url == $url
    and (.api_key | type == "string" and length > 0)
  ' "$PAUSED_CONFIG" >/dev/null 2>&1 \
  || proof_die "the DEV registration did not write one owner-only config for the exact DEV API"

FAILURE_PHASE="dev_connect"
jq -r '.api_key' "$PAUSED_CONFIG" \
  | with_alarm "$CLI_TIMEOUT" "${CAND_ENV[@]}" "$CANDIDATE_CLI" --data-dir "$PROOF_HOME" \
      cloud backup-v2 connect --existing --env dev --api-key-stdin \
      --expected-user-hash "$user_hash" --json \
      >"$PROOF_ROOT_REAL/connect.json" 2>"$PROOF_ROOT_REAL/connect.err" \
  || proof_die "the exact candidate could not connect the trial clone to DEV V2 backup"
jq -e --arg h "$user_hash" --arg uuid "$_DEV_V2_UUID_RE" '
    .ok == true and .account_id == $h and .user_hash == $h and .environment == "dev"
    and .manual_backup_enabled == true and .automatic_backup_enabled == false
    and .registration_attempted == false and (.source_home | type == "string" and test($uuid))
  ' "$PROOF_ROOT_REAL/connect.json" >/dev/null 2>&1 \
  || proof_die "the DEV connection is not a manual-only DEV connection for this identity"
source_home="$(jq -r '.source_home' "$PROOF_ROOT_REAL/connect.json")"

FAILURE_PHASE="dev_backup"
request_id="$(uuidgen | tr 'A-Z' 'a-z')"
cand_cli start --data-dir "$PROOF_HOME" cloud backup-v2 start --request-id "$request_id" --json \
  || proof_die "the exact candidate could not start a manual DEV V2 backup"
jq -e --arg r "$request_id" '.ok == true and .request_id == $r' \
  "$PROOF_ROOT_REAL/start.json" >/dev/null 2>&1 \
  || proof_die "the manual DEV V2 backup did not accept this request"
backup_deadline=$(($(date +%s) + BACKUP_TIMEOUT))
while :; do
  cand_cli status --data-dir "$PROOF_HOME" cloud backup-v2 status --json \
    || proof_die "the exact candidate did not report V2 status during the DEV backup"
  jq -e --arg r "$request_id" '.request_id == $r and .running == false' \
    "$PROOF_ROOT_REAL/status.json" >/dev/null 2>&1 && break
  [ "$(date +%s)" -lt "$backup_deadline" ] \
    || proof_die "the manual DEV V2 backup did not finish in ${BACKUP_TIMEOUT}s"
  sleep 2
done
jq -e --arg r "$request_id" --arg h "$user_hash" --arg uuid "$_DEV_V2_UUID_RE" '
    .ok == true and .phase == "published" and .backup_kind == "snapshot"
    and .user_hash == $h and .automatic_backup_enabled == false
    and (.last_accepted_backup | type == "object")
    and .last_accepted_backup.begin.job.commit_id == $r
    and .last_accepted_backup.begin.job.stream.scope.account_id == $h
    and (.last_accepted_backup.begin.job.stream.stream_id | type == "string" and test($uuid))
    and (.last_accepted_backup.begin.job.stream.scope.account_generation
      | type == "string" and test("^[0-9]+$"))
    and (.last_accepted_backup.commit_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$PROOF_ROOT_REAL/status.json" >/dev/null 2>&1 \
  || proof_die "the manual DEV V2 backup did not publish this request as an accepted snapshot"
stream_id="$(jq -r '.last_accepted_backup.begin.job.stream.stream_id' "$PROOF_ROOT_REAL/status.json")"
generation="$(jq -r '.last_accepted_backup.begin.job.stream.scope.account_generation' "$PROOF_ROOT_REAL/status.json")"
commit_sha256="$(jq -r '.last_accepted_backup.commit_sha256' "$PROOF_ROOT_REAL/status.json")"

FAILURE_PHASE="source_stop"
strict_stop "$SOURCE_PID" "$SOURCE_START_TS" "$PROOF_HOME" \
  || proof_die "the trial clone did not stop with its exact flush receipt"
SOURCE_PID=""
[ "$(dev_stamp_sha256_file "$PROOF_HOME/identity.key")" = "$identity_before" ] \
  || proof_die "the DEV connection or backup changed the cloned identity"

# The restore home holds only the paused DEV config. The recovery phrase is a
# BIP39 form of the seed identity; it goes from the helper to the CLI on a pipe.
FAILURE_PHASE="source_free_restore"
CREDS_HOME="$PROOF_ROOT_REAL/restore-credentials"
mkdir -m 700 "$CREDS_HOME"
cp -p "$PAUSED_CONFIG" "$CREDS_HOME/cloud_sync.json.paused" \
  || proof_die "the DEV config cannot be copied for the restore"
[ "$(ls -A "$CREDS_HOME")" = "cloud_sync.json.paused" ] \
  || proof_die "the restore credential home holds more than the paused DEV config"
python3 -I "$PHRASE_HELPER" --seed-file "$PROOF_HOME/identity.key" \
  | with_alarm "$RESTORE_TIMEOUT" "${CAND_ENV[@]}" "$CANDIDATE_CLI" --data-dir "$CREDS_HOME" \
      cloud backup-v2 restore --recovery-phrase-stdin --stream "$stream_id" \
      --generation "$generation" --commit "$request_id" --commit-sha256 "$commit_sha256" \
      --into "$RESTORED_HOME" --json \
      >"$PROOF_ROOT_REAL/restore.json" 2>"$PROOF_ROOT_REAL/restore.err" \
  || proof_die "the exact DEV V2 commit did not restore into a source-free home"
jq -e --arg d "$RESTORED_HOME" --arg c "$commit_sha256" '
    .commit_sha256 == $c and .destination == $d and .file_dependencies_verified == true
    and (.native_files | type == "number" and . > 0)
    and (.native_bytes | type == "number" and . > 0)
  ' "$PROOF_ROOT_REAL/restore.json" >/dev/null 2>&1 \
  || proof_die "the V2 restore report does not name the published commit and this home"
jq -e --slurpfile report "$PROOF_ROOT_REAL/restore.json" \
    '.version == 2 and .report == $report[0]' \
    "$RESTORED_HOME/byte-cloud-restore-receipt.json" >/dev/null 2>&1 \
  || proof_die "the restored home receipt differs from the restore report"
native_files="$(jq -r '.native_files' "$PROOF_ROOT_REAL/restore.json")"
native_bytes="$(jq -r '.native_bytes' "$PROOF_ROOT_REAL/restore.json")"
# Cloud Off: no connection, intent, store, or source state in the new home.
for rel in cloud_sync.json cloud_sync.json.paused native_cloud_backup \
    cloud-byte-backup-v2-manual.json data/cloud-byte-backup-v2/active.json \
    data/disk-run/cloud-byte-backup-v2 data/disk-run/cloud-byte-source-v2; do
  [ ! -e "$RESTORED_HOME/$rel" ] && [ ! -L "$RESTORED_HOME/$rel" ] \
    || proof_die "the restored home is not Cloud Off ($rel)"
done
cmp -s "$RESTORED_HOME/identity.key" "$PROOF_HOME/identity.key" \
  || proof_die "the restored home has another identity"

FAILURE_PHASE="restored_boot"
start_candidate "$RESTORED_HOME" "$RESTORED_LOG"
RESTORED_PID="$STARTED_PID"
wait_ready "$RESTORED_PID" "$RESTORED_HOME" \
  || proof_die "the exact candidate did not serve the restored home"
RESTORED_START_TS="$READY_START_TS"

# The seed's app configs name the seed build socket. A private copy names the
# restored socket, and the batch verify reads every known seed key exactly.
FAILURE_PHASE="restored_keys"
VERIFY_CLI_HOME="$PROOF_ROOT_REAL/cli-home"
mkdir -m 700 "$VERIFY_CLI_HOME" "$VERIFY_CLI_HOME/.brain" "$VERIFY_CLI_HOME/.lastsecrets"
for name in .brain .lastsecrets; do
  (umask 077; jq --arg s "$RESTORED_HOME/data/folddb.sock" '.nodeSocketPath = $s' \
    "$CLI_HOME/$name/config.json" >"$VERIFY_CLI_HOME/$name/config.json") \
    || proof_die "the seed app config cannot be copied for the key read"
done
with_alarm "$CLI_TIMEOUT" python3 -I "$BATCH_HELPER" verify --home "$RESTORED_HOME" \
    --cli-home "$VERIFY_CLI_HOME" --primary-home "$PRIMARY_HOME_ARG" \
    --cards "$CARDS" --records "$RECORDS" \
    >"$PROOF_ROOT_REAL/verify.json" 2>"$PROOF_ROOT_REAL/verify.err" \
  || proof_die "the restored home does not hold every known seed key"
jq -e --argjson c "$CARDS" --argjson r "$RECORDS" '
    .ok == true and .mode == "verify" and .cards == $c and .records == $r
    and .native_batch_calls == 1 and (.known_keys | type == "number" and . > 0)
  ' "$PROOF_ROOT_REAL/verify.json" >/dev/null 2>&1 \
  || proof_die "the restored key read report is incomplete"
known_keys="$(jq -r '.known_keys' "$PROOF_ROOT_REAL/verify.json")"

FAILURE_PHASE="restored_stop"
strict_stop "$RESTORED_PID" "$RESTORED_START_TS" "$RESTORED_HOME" \
  || proof_die "the restored home did not stop with its exact flush receipt"
RESTORED_PID=""
assert_candidate_binding_matches_expected \
    "$CANDIDATE_DAEMON" "$CANDIDATE_CLI" "$SOURCE_OID" >/dev/null 2>&1 \
  || proof_die "the exact candidate binding changed during the V2 DEV proof"

FAILURE_PHASE="receipt_write"
receipt_dir="$(dirname -- "$RECEIPT")"
mkdir -p -- "$receipt_dir" && chmod 700 "$receipt_dir" \
  || proof_die "the DEV receipt directory cannot be prepared"
[ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] \
  || proof_die "the DEV receipt directory is unsafe"
evidence="${RECEIPT}.restore.json"
[ ! -L "$evidence" ] || proof_die "the V2 DEV restore evidence path is unsafe"
rm -f -- "$RECEIPT" "$evidence" || proof_die "the prior exact receipt cannot be removed"
evidence_tmp="$(umask 077; mktemp "$receipt_dir/.restore-report.XXXXXX")" \
  || proof_die "the V2 DEV restore evidence file cannot be created"
if ! jq -cn --arg c "$commit_sha256" --argjson f "$native_files" --argjson b "$native_bytes" \
      --argjson k "$known_keys" \
      '{commit_sha256: $c, file_dependencies_verified: true, native_files: $f,
        native_bytes: $b, known_keys: $k, cloud_off: true}' >"$evidence_tmp" \
    || ! chmod 600 "$evidence_tmp" || ! mv -f -- "$evidence_tmp" "$evidence"; then
  rm -f -- "$evidence_tmp"
  proof_die "the V2 DEV restore evidence cannot be retained safely"
fi
evidence_sha256="$(dev_stamp_sha256_file "$evidence")" \
  || proof_die "the V2 DEV restore evidence digest is unavailable"
committed_epoch="$(date +%s)"
committed_at="$(date -u -r "$committed_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$committed_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
write_dev_v2_restore_receipt \
  "$RECEIPT" "$PRIMARY_HOME_ARG" "$PROOF_HOME" "$CLONE_SOURCE" "$user_hash" \
  "$source_home" "$stream_id" "$generation" "$request_id" "$commit_sha256" \
  "$native_files" "$native_bytes" "$known_keys" "$evidence_sha256" \
  "$committed_at" "$committed_epoch" \
  || proof_die "the exact-candidate V2 DEV restore receipt could not be written"
assert_dev_v2_restore_stamp_ok "$RECEIPT" "$PRIMARY_HOME_ARG" "$CLONE_SOURCE" >/dev/null \
  || proof_die "the exact-candidate V2 DEV restore receipt failed its own gate"

FAILURE_PHASE="complete"
printf 'DEV_V2_RESTORE: GREEN\n'
printf 'DEV_V2_RESTORE_SUMMARY: native_files=%s native_bytes=%s known_keys=%s\n' \
  "$native_files" "$native_bytes" "$known_keys"
