#!/usr/bin/env bash
# Prove that one exact lastdb/lastdbd pair can publish a real-data photograph
# to DEV. This helper never points a candidate at the live primary home.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dev-photograph-stamp-gate.sh
. "$SCRIPT_DIR/dev-photograph-stamp-gate.sh"

DEV_INVITE_SLUG="lastdb-restore-probe-invite-dev-20260720"
CANDIDATE_DAEMON=""
CANDIDATE_CLI=""
PRIMARY_HOME_ARG=""
CLONE_SOURCE=""
RECEIPT=""
SOURCE_OID=""
LASTSECRETS_BIN="${LASTDB_DEV_PHOTOGRAPH_LASTSECRETS_BIN:-lastsecrets}"
PROOF_ROOT=""
PROOF_ROOT_REAL=""
PROOF_SENTINEL=""
PROOF_TOKEN=""
COW_HOME=""
CANDIDATE_PID=""

usage() {
  cat <<'EOF'
Usage: dev-photograph-candidate-proof.sh \
  --candidate-lastdbd PATH --candidate-lastdb PATH \
  --primary-home PATH --clone-source PATH --receipt PATH --source-git-oid OID

The immutable hashes, versions, paths, source OID, and Loom execution ID must
also exist in the LASTDB_SAFE_UPGRADE_EXPECTED_* and LOOM_EXEC_ID variables.
EOF
}

proof_die() {
  printf 'DEV_PHOTOGRAPH: RED\n' >&2
  printf 'REASON: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate-lastdbd) [ "$#" -ge 2 ] || proof_die "candidate daemon argument is incomplete"; CANDIDATE_DAEMON="$2"; shift 2 ;;
    --candidate-lastdb) [ "$#" -ge 2 ] || proof_die "candidate CLI argument is incomplete"; CANDIDATE_CLI="$2"; shift 2 ;;
    --primary-home) [ "$#" -ge 2 ] || proof_die "primary home argument is incomplete"; PRIMARY_HOME_ARG="$2"; shift 2 ;;
    --clone-source) [ "$#" -ge 2 ] || proof_die "clone source argument is incomplete"; CLONE_SOURCE="$2"; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || proof_die "receipt argument is incomplete"; RECEIPT="$2"; shift 2 ;;
    --source-git-oid) [ "$#" -ge 2 ] || proof_die "source OID argument is incomplete"; SOURCE_OID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) proof_die "unknown DEV photograph proof argument" ;;
  esac
done

[ -n "$CANDIDATE_DAEMON" ] || proof_die "candidate daemon is absent"
[ -n "$CANDIDATE_CLI" ] || proof_die "candidate CLI is absent"
[ -n "$PRIMARY_HOME_ARG" ] || proof_die "primary home is absent"
[ -n "$CLONE_SOURCE" ] || proof_die "the static rollback clone source is absent"
[ -n "$RECEIPT" ] || proof_die "receipt path is absent"
[ -n "$SOURCE_OID" ] || proof_die "source OID is absent"
case "$RECEIPT" in /*) ;; *) proof_die "receipt path is not absolute" ;; esac

if ! command -v jq >/dev/null 2>&1; then
  proof_die "jq is unavailable"
fi
if [ ! -x "$LASTSECRETS_BIN" ] && ! command -v "$LASTSECRETS_BIN" >/dev/null 2>&1; then
  proof_die "LastSecrets is unavailable"
fi

if ! assert_candidate_binding_matches_expected \
    "$CANDIDATE_DAEMON" "$CANDIDATE_CLI" "$SOURCE_OID" >/dev/null 2>&1; then
  proof_die "the exact candidate binding changed before the DEV proof"
fi

CANDIDATE_DAEMON="$(_dev_stamp_real_file "$CANDIDATE_DAEMON")"
CANDIDATE_CLI="$(_dev_stamp_real_file "$CANDIDATE_CLI")"
PRIMARY_HOME_ARG="$(_dev_stamp_real_dir "$PRIMARY_HOME_ARG")" \
  || proof_die "the primary home cannot resolve"
CLONE_SOURCE="$(_dev_stamp_real_dir "$CLONE_SOURCE")" \
  || proof_die "the static rollback clone source cannot resolve"
[ -d "$PRIMARY_HOME_ARG/data" ] || proof_die "the primary data directory is absent"
[ ! -L "$PRIMARY_HOME_ARG" ] || proof_die "the primary home argument is a symlink"
[ -d "$CLONE_SOURCE/data" ] && [ ! -L "$CLONE_SOURCE" ] && [ ! -L "$CLONE_SOURCE/data" ] \
  || proof_die "the static rollback clone source is absent or unsafe"
if ! _dev_stamp_paths_do_not_overlap "$CLONE_SOURCE" "$PRIMARY_HOME_ARG"; then
  proof_die "the DEV proof clone source overlaps the live primary"
fi
[ -f "$PRIMARY_HOME_ARG/identity.key" ] && [ ! -L "$PRIMARY_HOME_ARG/identity.key" ] \
  || proof_die "the primary identity file is absent or unsafe"
[ -f "$PRIMARY_HOME_ARG/.bootstrap_done" ] && [ ! -L "$PRIMARY_HOME_ARG/.bootstrap_done" ] \
  || proof_die "the primary bootstrap marker is absent or unsafe"
[ -f "$PRIMARY_HOME_ARG/data/.device_id" ] && [ ! -L "$PRIMARY_HOME_ARG/data/.device_id" ] \
  || proof_die "the primary device ID is absent or unsafe"

proof_tmp_base="${LASTDB_DEV_PHOTOGRAPH_TMP_ROOT:-/tmp}"
proof_tmp_base="$(_dev_stamp_real_dir "$proof_tmp_base")" \
  || proof_die "the DEV proof temporary root cannot resolve"
case "$proof_tmp_base" in /|"") proof_die "the DEV proof temporary root is unsafe" ;; esac
if ! _dev_stamp_paths_do_not_overlap "$proof_tmp_base/dev-photograph-placeholder" "$PRIMARY_HOME_ARG"; then
  proof_die "the DEV proof temporary root overlaps the primary home"
fi
safe_exec_id="$(printf '%s' "${LOOM_EXEC_ID:-missing}" | tr -c 'A-Za-z0-9._-' '_')"

# The caller cannot redirect receipt deletion or output. The exact safe path
# derives from this Loom execution and both expected binary hashes.
receipt_root="$(dev_stamp_receipt_root)"
case "$receipt_root" in /*) ;; *) proof_die "the DEV receipt root is not absolute" ;; esac
receipt_root_real="$(_dev_stamp_real_maybe_absent "$receipt_root")" \
  || proof_die "the DEV receipt root cannot resolve"
case "$receipt_root_real" in /|"") proof_die "the DEV receipt root is unsafe" ;; esac
[ ! -e "$receipt_root" ] || { [ -d "$receipt_root" ] && [ ! -L "$receipt_root" ]; } \
  || proof_die "the DEV receipt root is not a real directory"
if ! _dev_stamp_paths_do_not_overlap "$receipt_root_real/receipt-placeholder" "$PRIMARY_HOME_ARG"; then
  proof_die "the DEV receipt root overlaps the live primary"
fi
expected_receipt_name="${safe_exec_id}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:0:16}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:0:16}.receipt"
receipt_parent_real="$(_dev_stamp_real_maybe_absent "$(dirname -- "$RECEIPT")")" \
  || proof_die "the DEV receipt parent cannot resolve"
[ "$receipt_parent_real" = "$receipt_root_real" ] \
  && [ "$(basename -- "$RECEIPT")" = "$expected_receipt_name" ] \
  && [ ! -L "$RECEIPT" ] \
  || proof_die "the DEV receipt path is not bound to this execution and candidate pair"
RECEIPT="$receipt_root_real/$expected_receipt_name"

PROOF_ROOT="$(mktemp -d "$proof_tmp_base/lastdb-dev-photograph-${safe_exec_id}.XXXXXX")" \
  || proof_die "the DEV proof root cannot be created"
PROOF_ROOT_REAL="$(_dev_stamp_real_dir "$PROOF_ROOT")" \
  || proof_die "the DEV proof root cannot resolve"
COW_HOME="$PROOF_ROOT_REAL/cow"
PROOF_SENTINEL="$PROOF_ROOT_REAL/.lastdb-dev-photograph-owner"
PROOF_TOKEN="${LOOM_EXEC_ID}:$$:${PROOF_ROOT_REAL}"
(umask 077; printf '%s\n' "$PROOF_TOKEN" >"$PROOF_SENTINEL")
chmod 600 "$PROOF_SENTINEL"

proof_root_is_owned() {
  local base_real
  [ -n "$PROOF_ROOT_REAL" ] && [ -n "$PROOF_SENTINEL" ] && [ -f "$PROOF_SENTINEL" ] \
    || return 1
  [ ! -L "$PROOF_SENTINEL" ] || return 1
  [ "$(cat "$PROOF_SENTINEL" 2>/dev/null || true)" = "$PROOF_TOKEN" ] || return 1
  base_real="$(_dev_stamp_real_dir "$proof_tmp_base")" || return 1
  case "$PROOF_ROOT_REAL" in "$base_real"/*) ;;
    *) return 1 ;;
  esac
  [ "$PROOF_ROOT_REAL" != "$base_real" ]
}

candidate_pid_is_owned() {
  local command_line
  [ -n "$CANDIDATE_PID" ] || return 1
  kill -0 "$CANDIDATE_PID" 2>/dev/null || return 1
  command_line="$(ps -p "$CANDIDATE_PID" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *"$CANDIDATE_DAEMON"*"$COW_HOME"*) return 0 ;;
  esac
  return 1
}

stop_exact_candidate() {
  if candidate_pid_is_owned; then
    kill "$CANDIDATE_PID" 2>/dev/null || true
    local wait_n=0
    while kill -0 "$CANDIDATE_PID" 2>/dev/null && [ "$wait_n" -lt 50 ]; do
      sleep 0.1
      wait_n=$((wait_n + 1))
    done
    if candidate_pid_is_owned; then
      kill -KILL "$CANDIDATE_PID" 2>/dev/null || true
    fi
    wait "$CANDIDATE_PID" 2>/dev/null || true
  fi
  CANDIDATE_PID=""
}

cleanup_dev_proof() {
  stop_exact_candidate
  if proof_root_is_owned; then
    rm -rf -- "$PROOF_ROOT_REAL"
  fi
}
trap cleanup_dev_proof EXIT
trap 'cleanup_dev_proof; exit 1' HUP INT TERM

file_fingerprint() {
  local path="$1" mode inode sha
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode="$(_dev_stamp_file_mode "$path")" || return 1
  inode="$(stat -f '%d:%i' "$path" 2>/dev/null || stat -c '%d:%i' "$path" 2>/dev/null)" \
    || return 1
  sha="$(dev_stamp_sha256_file "$path")" || return 1
  printf '%s:%s:%s\n' "$mode" "$inode" "$sha"
}

# Clone the static rollback point that step 1 already created. Do not race a
# second walk of the live primary after the normal probe bars.
cp -cR "$CLONE_SOURCE" "$COW_HOME" >/dev/null 2>&1 \
  || proof_die "the static rollback point cannot create the DEV proof CoW"
[ -d "$COW_HOME/data" ] \
  && [ -f "$COW_HOME/identity.key" ] \
  && [ -f "$COW_HOME/.bootstrap_done" ] \
  && [ -f "$COW_HOME/data/.device_id" ] \
  || proof_die "the CoW clone lacks a required durable file"
[ ! -L "$COW_HOME" ] && [ ! -L "$COW_HOME/data" ] \
  || proof_die "the CoW clone uses an unsafe directory symlink"
COW_HOME="$(_dev_stamp_real_dir "$COW_HOME")" || proof_die "the CoW home cannot resolve"
if ! _dev_stamp_paths_do_not_overlap "$COW_HOME" "$PRIMARY_HOME_ARG"; then
  proof_die "the CoW home overlaps the primary home"
fi

identity_before="$(file_fingerprint "$COW_HOME/identity.key")" \
  || proof_die "the copied identity file is unsafe"
bootstrap_before="$(file_fingerprint "$COW_HOME/.bootstrap_done")" \
  || proof_die "the copied bootstrap marker is unsafe"
production_device_id="$(cat "$COW_HOME/data/.device_id")"
[ -n "$production_device_id" ] || proof_die "the copied production device ID is empty"

# Remove every production cloud intent or backup, not only active and paused.
# The copied manifest can pass production lineage into the DEV CAS request.
find "$COW_HOME" -maxdepth 1 -name 'cloud_sync.json*' -exec rm -f -- {} + 2>/dev/null \
  || proof_die "a copied cloud credential residue cannot be removed"
rm -f -- \
  "$COW_HOME/data/folddb.sock" \
  "$COW_HOME/data/folddb-full.sock" \
  "$COW_HOME/data/.device_id" \
  "$COW_HOME/current-session.json" \
  "$COW_HOME/laststore_backup_known_present.json" \
  "$COW_HOME/laststore_backup_manifest.json" \
  || proof_die "a copied runtime or backup residue cannot be removed"

[ "$(find "$COW_HOME" -maxdepth 1 -name 'cloud_sync.json*' -print | wc -l | tr -d ' ')" = "0" ] \
  || proof_die "copied cloud credential residue remains before DEV connect"
for absent in \
  "$COW_HOME/data/folddb.sock" \
  "$COW_HOME/data/folddb-full.sock" \
  "$COW_HOME/data/.device_id" \
  "$COW_HOME/current-session.json" \
  "$COW_HOME/laststore_backup_known_present.json" \
  "$COW_HOME/laststore_backup_manifest.json"; do
  [ ! -e "$absent" ] && [ ! -L "$absent" ] \
    || proof_die "copied production runtime or backup residue remains before DEV connect"
done

# Keep the invite in one pipe. Do not store, print, log, or pass it in argv.
set +e
"$LASTSECRETS_BIN" get "$DEV_INVITE_SLUG" 2>/dev/null \
  | env -u LASTDB_HOME -u FOLDDB_HOME -u FOLD_SYNC_DEVICE_ID \
      "$CANDIDATE_CLI" --data-dir "$COW_HOME" connect \
        --env dev --invite-code-stdin --use-existing-identity \
        >/dev/null 2>/dev/null
connect_rc=$?
set -e
[ "$connect_rc" -eq 0 ] || proof_die "the exact candidate could not register the copied identity in DEV"

active_config="$COW_HOME/cloud_sync.json"
[ -f "$active_config" ] && [ ! -L "$active_config" ] \
  || proof_die "DEV connect did not create one safe active cloud config"
[ "$(_dev_stamp_file_mode "$active_config" || true)" = "600" ] \
  || proof_die "the DEV cloud config is not owner-only"
[ "$(find "$COW_HOME" -maxdepth 1 -name 'cloud_sync.json*' -print | wc -l | tr -d ' ')" = "1" ] \
  || proof_die "cloud credential backup residue remains after DEV connect"
jq -e --arg url "$LASTDB_DEV_BACKUP_API_URL_DEFAULT" \
  '.api_url == $url and (.api_key | type == "string" and length > 0) and ((keys | sort) == ["api_key","api_url"])' \
  "$active_config" >/dev/null 2>&1 \
  || proof_die "the new active cloud config does not name the exact DEV API"
[ -f "$COW_HOME/data/.device_id" ] && [ ! -L "$COW_HOME/data/.device_id" ] \
  || proof_die "DEV connect did not create a fresh device ID"
[ "$(_dev_stamp_file_mode "$COW_HOME/data/.device_id" || true)" = "600" ] \
  || proof_die "the fresh DEV device ID is not owner-only"
dev_device_id="$(cat "$COW_HOME/data/.device_id")"
[ -n "$dev_device_id" ] && [ "$dev_device_id" != "$production_device_id" ] \
  || proof_die "DEV connect reused the copied production device ID"
[ ! -e "$COW_HOME/current-session.json" ] && [ ! -L "$COW_HOME/current-session.json" ] \
  || proof_die "the copied primary session marker returned after DEV connect"
for absent in \
  "$COW_HOME/laststore_backup_known_present.json" \
  "$COW_HOME/laststore_backup_manifest.json"; do
  [ ! -e "$absent" ] && [ ! -L "$absent" ] \
    || proof_die "copied production backup residue returned after DEV connect"
done
[ "$(file_fingerprint "$COW_HOME/identity.key")" = "$identity_before" ] \
  || proof_die "DEV connect changed the copied identity"
[ "$(file_fingerprint "$COW_HOME/.bootstrap_done")" = "$bootstrap_before" ] \
  || proof_die "DEV connect changed the copied bootstrap marker"

# The continuous publisher starts at daemon boot. Only the explicit snapshot
# command below can supply the receipt report for this proof.
env -u LASTDB_HOME -u FOLDDB_HOME -u FOLD_SYNC_DEVICE_ID \
  "$CANDIDATE_DAEMON" --data-dir "$COW_HOME" >/dev/null 2>/dev/null &
CANDIDATE_PID=$!

socket="$COW_HOME/data/folddb.sock"
ready=0
ready_waits="${LASTDB_DEV_PHOTOGRAPH_READY_WAITS:-300}"
case "$ready_waits" in ''|*[!0-9]*) proof_die "the DEV proof readiness limit is invalid" ;; esac
ready_sleep="${LASTDB_DEV_PHOTOGRAPH_READY_SLEEP_SECS:-1}"
ready_n=0
while [ "$ready_n" -lt "$ready_waits" ]; do
  candidate_pid_is_owned || proof_die "the exact candidate stopped before the DEV snapshot"
  if [ -S "$socket" ]; then
    ready=1
    break
  fi
  sleep "$ready_sleep"
  ready_n=$((ready_n + 1))
done
[ "$ready" -eq 1 ] || proof_die "the exact candidate did not open its isolated socket"

snapshot_json=""
snapshot_ok=0
snapshot_attempts="${LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_ATTEMPTS:-3}"
snapshot_delay="${LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_RETRY_SECS:-5}"
case "$snapshot_attempts" in ''|*[!0-9]*|0) proof_die "the DEV snapshot attempt limit is invalid" ;; esac
attempt=1
while [ "$attempt" -le "$snapshot_attempts" ]; do
  candidate_pid_is_owned || proof_die "the exact candidate stopped during the DEV snapshot"
  set +e
  snapshot_json="$(env -u LASTDB_HOME -u FOLDDB_HOME -u FOLD_SYNC_DEVICE_ID \
    "$CANDIDATE_CLI" --data-dir "$COW_HOME" cloud snapshot --json 2>/dev/null)"
  snapshot_rc=$?
  set -e
  if [ "$snapshot_rc" -eq 0 ] \
      && printf '%s' "$snapshot_json" | jq -e '
        ((.report // .data.report) as $r
          | (.ok == true)
          and ($r.counter | type == "number" and . > 0)
          and ($r.cas_counter | type == "number" and . == $r.counter)
          and ($r.manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          and ($r.latest_key | type == "string" and length > 0))
      ' >/dev/null 2>&1; then
    snapshot_ok=1
    break
  fi
  snapshot_json=""
  [ "$attempt" -eq "$snapshot_attempts" ] || sleep "$snapshot_delay"
  attempt=$((attempt + 1))
done
[ "$snapshot_ok" -eq 1 ] || proof_die "the manual DEV photograph did not return an exact committed CAS report"

counter="$(printf '%s' "$snapshot_json" | jq -er '(.report // .data.report).counter')"
cas_counter="$(printf '%s' "$snapshot_json" | jq -er '(.report // .data.report).cas_counter')"
manifest_sha256="$(printf '%s' "$snapshot_json" | jq -er '(.report // .data.report).manifest_sha256')"
latest_key="$(printf '%s' "$snapshot_json" | jq -er '(.report // .data.report).latest_key')"
snapshot_json=""

stop_exact_candidate
[ "$(file_fingerprint "$COW_HOME/identity.key")" = "$identity_before" ] \
  || proof_die "the DEV photograph changed the copied identity"
[ "$(file_fingerprint "$COW_HOME/.bootstrap_done")" = "$bootstrap_before" ] \
  || proof_die "the DEV photograph changed the copied bootstrap marker"
if ! assert_candidate_binding_matches_expected \
    "$CANDIDATE_DAEMON" "$CANDIDATE_CLI" "$SOURCE_OID" >/dev/null 2>&1; then
  proof_die "the exact candidate binding changed during the DEV proof"
fi

committed_epoch="$(date +%s)"
committed_at="$(date -u -r "$committed_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$committed_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
rm -f -- "$RECEIPT" \
  || proof_die "the prior exact receipt cannot be removed"
write_dev_stamp_receipt_v2 \
  "$RECEIPT" "$PRIMARY_HOME_ARG" "$COW_HOME" \
  "$counter" "$cas_counter" "$manifest_sha256" "$latest_key" \
  "$committed_at" "$committed_epoch" \
  || proof_die "the exact-candidate DEV photograph receipt could not be written"
assert_dev_photograph_stamp_ok "$RECEIPT" "$PRIMARY_HOME_ARG" >/dev/null \
  || proof_die "the exact-candidate DEV photograph receipt failed its own gate"

printf 'DEV_PHOTOGRAPH: GREEN\n'
printf 'SUMMARY: the exact candidate pair committed one isolated DEV photograph\n'
