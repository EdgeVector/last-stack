#!/usr/bin/env bash
# Write-path CoW probe — Table 5 gate for T0-only mutation ack.
#
# Clone the live LastDB home with `cp -cR` into ${TMPDIR} (never under $HOME,
# never --data-dir ~/.lastdb), mirror live LASTDB_* except home/data-dir via
# live_lastdb_env_pairs(), strip production cloud_sync.json, boot the candidate
# on an isolated socket, identity-check the live socket before and after.
#
# On today's incumbent the same probe prints RED (seconds-scale BoardCards
# ack; persist and T2 on the request; Purge in the batch). Table 5 GREEN is
# persist spawn-only, sync_capture encode-only, purge_barrier ≈ 0, warm
# p50 < 50 ms / p95 < 100 ms, RYW at ack.
#
# Usage:
#   write-path-cow-probe.sh --classify --sample-file sample.json
#   write-path-cow-probe.sh --lastdbd /path/to/lastdbd [--probe-defer] [--kill9]
#   write-path-cow-probe.sh --refuse-data-dir PATH
#
# Exit: 0 GREEN (or classify GREEN); 1 RED; 2 usage.
set -euo pipefail

PROBE_NAME="write-path-cow-probe"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=live-lastdb-env.sh
. "$_SCRIPT_DIR/live-lastdb-env.sh"
# shellcheck source=write-path-cow-checks.sh
. "$_SCRIPT_DIR/write-path-cow-checks.sh"

PRIMARY_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
PRIMARY_SOCK="$PRIMARY_HOME/data/folddb.sock"
LAUNCHD_PLIST="${LASTDB_LAUNCHD_PLIST:-}"
if [ -z "$LAUNCHD_PLIST" ]; then
  LAUNCHD_PLIST="$(ls "$HOME"/Library/LaunchAgents/*lastdbd-primary*.plist 2>/dev/null | head -1 || true)"
fi

LASTDBD_BIN=""
CLASSIFY=0
SAMPLE_FILE=""
REFUSE_DATA_DIR=""
PROBE_DEFER=0
DO_KILL9=0
SAMPLES="${LASTDB_WRITE_PATH_SAMPLES:-7}"
CLONE_ROOT=""

usage() {
  sed -n '2,22p' "$0"
  exit 2
}

log() { printf '[%s] %s\n' "$PROBE_NAME" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$PROBE_NAME" "$*" >&2; }

fail_red() {
  echo ""
  echo "VERDICT: RED"
  echo "CANDIDATE: ${LASTDBD_BIN:-unknown}"
  echo "REASON: $*"
  echo "NEXT:   do NOT live-upgrade this binary; keep the primary on the incumbent."
  exit 1
}

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null \
    || perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
}

median_of() {
  python3 -c 'import sys
a=sorted(int(x) for x in sys.argv[1:] if str(x).lstrip("-").isdigit())
n=len(a)
print(-1 if n==0 else (a[n//2] if n%2 else (a[n//2-1]+a[n//2])//2))' "$@"
}

p95_of() {
  python3 -c 'import sys
a=sorted(int(x) for x in sys.argv[1:] if str(x).lstrip("-").isdigit())
n=len(a)
if n==0:
    print(-1)
else:
    idx=min(n-1, max(0, int((n*95+99)/100)-1))
    print(a[idx])' "$@"
}

curl_sock() {
  local sock="$1" path="$2"
  shift 2
  curl -sS --max-time 15 --unix-socket "$sock" -H 'Host: localhost' "$@" "http://x${path}"
}

live_identity() {
  local sock="${1:-$PRIMARY_SOCK}"
  [ -S "$sock" ] || { echo ""; return 0; }
  curl_sock "$sock" /api/system/auto-identity 2>/dev/null \
    | jq -r '.user_hash // empty' 2>/dev/null || true
}

live_pid() {
  if [ -S "$PRIMARY_SOCK" ]; then
    lsof -t -U "$PRIMARY_SOCK" 2>/dev/null | head -1 || true
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --classify) CLASSIFY=1; shift ;;
    --sample-file) SAMPLE_FILE="$2"; shift 2 ;;
    --lastdbd) LASTDBD_BIN="$2"; shift 2 ;;
    --refuse-data-dir) REFUSE_DATA_DIR="$2"; shift 2 ;;
    --probe-defer) PROBE_DEFER=1; shift ;;
    --kill9) DO_KILL9=1; shift ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --clone-root) CLONE_ROOT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$CLASSIFY" -eq 1 ]; then
  [ -n "$SAMPLE_FILE" ] || { echo "FAIL: --sample-file required with --classify" >&2; exit 2; }
  set +e
  out="$(write_path_classify_json_file "$SAMPLE_FILE")"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ]; then
    echo "VERDICT: GREEN"
  else
    echo "VERDICT: RED"
  fi
  exit "$rc"
fi

if [ -n "$REFUSE_DATA_DIR" ]; then
  if write_path_data_dir_is_live_home "$REFUSE_DATA_DIR" "$PRIMARY_HOME"; then
    echo "RED: --data-dir $REFUSE_DATA_DIR is the live home ($PRIMARY_HOME); refuse"
    echo "VERDICT: RED"
    exit 1
  fi
  echo "GREEN: --data-dir $REFUSE_DATA_DIR is not the live home"
  echo "VERDICT: GREEN"
  exit 0
fi

[ -n "$LASTDBD_BIN" ] || { echo "FAIL: --lastdbd PATH is required" >&2; exit 2; }
[ -x "$LASTDBD_BIN" ] || fail_red "candidate not executable: $LASTDBD_BIN"

if write_path_data_dir_is_live_home "${LASTDB_PROBE_DATA_DIR:-}" "$PRIMARY_HOME" 2>/dev/null; then
  fail_red "refusing live-home --data-dir ${LASTDB_PROBE_DATA_DIR}"
fi

# Clone must land under TMPDIR, never under $HOME.
tmp="${TMPDIR:-/tmp}"
case "$tmp" in
  "$HOME"|"$HOME"/*)
    fail_red "TMPDIR $tmp is under HOME; CoW clone must not land under \$HOME"
    ;;
esac

if [ -z "$CLONE_ROOT" ]; then
  # sockaddr_un is 103 bytes; lastdbd refuses a data dir longer than 82.
  # Keep the clone name tiny under TMPDIR (never $HOME).
  CLONE_ROOT="$(mktemp -d "${tmp%/}/w.XXXXXX")"
fi
copy="$CLONE_ROOT/h"
sock="$copy/data/folddb.sock"
blog="$CLONE_ROOT/boot.log"
phase_log="$CLONE_ROOT/phase.json"
sample_out="$CLONE_ROOT/sample.json"

cleanup() {
  if [ -n "${CANDIDATE_PID:-}" ]; then
    kill -TERM "$CANDIDATE_PID" 2>/dev/null || true
    wait "$CANDIDATE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

LIVE_ID_BEFORE="$(live_identity "$PRIMARY_SOCK")"
LIVE_PID_BEFORE="$(live_pid)"
log "live identity before=$(printf '%s' "$LIVE_ID_BEFORE" | cut -c1-12) pid=${LIVE_PID_BEFORE:-none}"

if [ ! -d "$PRIMARY_HOME" ] || [ ! -f "$PRIMARY_HOME/identity.key" ]; then
  fail_red "live home missing identity.key at $PRIMARY_HOME"
fi

log "cloning $PRIMARY_HOME -> $copy (cp -cR)"
rm -rf "$copy"
cp -cR "$PRIMARY_HOME" "$copy" 2>/dev/null || true
if [ ! -d "$copy" ] || [ ! -f "$copy/identity.key" ] || [ ! -d "$copy/data" ]; then
  fail_red "CoW clone incomplete at $copy"
fi
rm -f "$copy/cloud_sync.json" "$copy/data/"*.sock 2>/dev/null || true
# Never let the probe upload to the production backup home.
unset LASTDB_CLOUD_SYNC LASTDB_BACKUP_HOME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY 2>/dev/null || true

if write_path_data_dir_is_live_home "$copy" "$PRIMARY_HOME"; then
  fail_red "clone resolved to the live home"
fi

env_pairs=()
while IFS= read -r line; do
  [ -n "$line" ] && env_pairs+=("$line")
done <<EOF_ENV
$(live_lastdb_env_pairs "$LAUNCHD_PLIST")
EOF_ENV
if [ "${#env_pairs[@]}" -gt 0 ]; then
  log "mirroring live env: ${env_pairs[*]}"
fi
# Probe-only defer is allowed here; do not touch the live plist.
if [ "$PROBE_DEFER" -eq 1 ]; then
  env_pairs+=("LASTDB_RESIDENT_MAX_DEFERRED_BYTES=67108864")
  log "probe-only defer window LASTDB_RESIDENT_MAX_DEFERRED_BYTES=67108864"
fi

env -u SENTRY_DSN -u FOLD_SENTRY_DSN ${env_pairs[@]+"${env_pairs[@]}"} \
  "$LASTDBD_BIN" --data-dir "$copy" >"$blog" 2>&1 &
CANDIDATE_PID=$!
log "booted candidate pid=$CANDIDATE_PID data-dir=$copy"

uh=""
for i in $(seq 1 180); do
  if ! kill -0 "$CANDIDATE_PID" 2>/dev/null; then
    fail_red "candidate exited during boot ($(tail -3 "$blog" 2>/dev/null | tr '\n' ' '))"
  fi
  if [ -S "$sock" ]; then
    uh="$(live_identity "$sock")"
    [ -n "$uh" ] && break
  fi
  sleep 1
done
[ -n "$uh" ] || fail_red "candidate identity not ready in 180s"

log "candidate identity=$(printf '%s' "$uh" | cut -c1-12) sock=$sock"

# Warm: list BoardCards titles so the partition is resident.
kanban_list_probe() {
  LASTDB_HOME="$copy" LASTDB_SOCKET_PATH="$sock" FOLDDB_SOCKET_PATH="$sock" \
    kanban list --column todo 2>/dev/null || true
}
log "warming BoardCards via kanban list"
kanban_list_probe >/dev/null || true

# Prefer the live kanban pin for BoardCards; fall back to /api/schemas.
bc_hash=""
if [ -f "$HOME/.fkanban/config.json" ]; then
  bc_hash="$(jq -r '.schemaHashes.board_cards // empty' "$HOME/.fkanban/config.json" 2>/dev/null || true)"
fi
schema_json="$(curl_sock "$sock" /api/schemas 2>/dev/null || true)"
if [ -z "$bc_hash" ]; then
  bc_hash="$(printf '%s' "$schema_json" | jq -r '
    [.schemas[]? | select((.descriptive_name // .name // "") | test("BoardCards";"i"))]
    | (map(select(.name != null)) | .[0].name) // .[0].identity_hash // empty
  ' 2>/dev/null || true)"
fi

timed_write_ms() {
  local body="$1"
  local out code secs ms
  out="$(curl -sS --max-time 60 --unix-socket "$sock" -H 'Host: localhost' \
    -H 'Content-Type: application/json' -H 'X-LastDB-Client: write-path-cow-probe' \
    ${uh:+-H "X-User-Hash: $uh"} \
    -o "$CLONE_ROOT/mut-body.json" -w '%{http_code} %{time_total}' \
    -X POST -d "$body" "http://x/api/mutation" 2>/dev/null || echo '000 0')"
  code="${out%% *}"
  secs="${out#* }"
  ms="$(awk -v s="${secs:-0}" 'BEGIN{printf "%d", (s+0)*1000+0.5}')"
  echo "$code $ms"
}

# Build a ~1 KB BoardCards update of a throwaway probe slug. If we cannot
# discover BoardCards, fall back to a generic mutation and still classify
# phases from /api/status.
payload="$(python3 -c 'print("x"*1024)')"
slug="write-path-cow-probe"
sk="todo#0#${slug}"
mut_body="$(jq -n --arg h "$bc_hash" --arg p "$payload" --arg slug "$slug" --arg sk "$sk" '{
  type: "mutation",
  schema: ($h | if . == "" then "BoardCards" else . end),
  mutation_type: "update",
  fields_and_values: {
    slug: $slug,
    title: $p,
    board: "default",
    column: "todo",
    position: "0",
    sk: $sk,
    assignee: "",
    tags: [],
    deps: [],
    surfaces: [],
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-08-19T00:00:00.000Z",
    db: "",
    repo: "",
    base: "",
    kind: "pr",
    block_status: "",
    block_reason: "",
    north_star: "",
    pr_url: "",
    branch: "",
    layout: ""
  },
  key_value: {hash: "default", range: $sk}
}')"
read_body="$(jq -n --arg h "$bc_hash" --arg slug "$slug" '{
  schema_name: ($h | if . == "" then "BoardCards" else . end),
  fields: ["slug","title"],
  filter: {HashRangePrefix: {hash: "default", prefix: ("todo#0#" + $slug)}}
}')"

wait_t1_idle() {
  local i inflight
  for i in $(seq 1 45); do
    inflight="$(curl_sock "$sock" /api/status 2>/dev/null | jq -r '
      .status.memory_budget.deferred_persist_bytes
      // .memory_budget.deferred_persist_bytes
      // 0
    ' 2>/dev/null || echo 0)"
    inflight="${inflight:-0}"
    if [ "$inflight" = "0" ] || [ "$inflight" = "null" ]; then
      return 0
    fi
    sleep 1
  done
  warn "T1 drain still inflight=${inflight:-?} after 45s"
}

log "warming one write (schema=$bc_hash)"
warm="$(timed_write_ms "$mut_body")"
log "warm write: $warm"
wait_t1_idle
# Rehydrate the key we just wrote so the timed warm path is T0 RAM, not a
# cold restore after dirty tips became evictable.
q="$(curl_sock "$sock" /api/query -H 'Content-Type: application/json' ${uh:+-H "X-User-Hash: $uh"} -d "$read_body" 2>/dev/null || true)"
log "T1 idle after warmup; rehydrate query bytes=${#q}"

vals=""
n=0
last_code=""
i=0
while [ "$i" -lt "$SAMPLES" ]; do
  i=$((i + 1))
  mut_body="$(jq -n --arg h "$bc_hash" --arg p "${payload}$i" --arg slug "$slug" --arg sk "$sk" '{
    type: "mutation",
    schema: ($h | if . == "" then "BoardCards" else . end),
    mutation_type: "update",
    fields_and_values: {
      slug: $slug, title: $p, board: "default", column: "todo", position: "0", sk: $sk,
      assignee: "", tags: [], deps: [], surfaces: [],
      created_at: "2026-01-01T00:00:00.000Z", updated_at: "2026-08-19T00:00:00.000Z",
      db: "", repo: "", base: "", kind: "pr", block_status: "", block_reason: "",
      north_star: "", pr_url: "", branch: "", layout: ""
    },
    key_value: {hash: "default", range: $sk}
  }')"
  rec="$(timed_write_ms "$mut_body")"
  code="${rec%% *}"
  ms="${rec#* }"
  last_code="$code"
  log "sample $i http=$code ms=$ms"
  if [ "$code" = "200" ]; then
    vals="$vals $ms"
    n=$((n + 1))
  fi
  wait_t1_idle
done

p50="-1"
p95="-1"
if [ "$n" -gt 0 ]; then
  # shellcheck disable=SC2086
  p50="$(median_of $vals)"
  # shellcheck disable=SC2086
  p95="$(p95_of $vals)"
fi
log "timed writes n=$n p50=${p50}ms p95=${p95}ms"
if [ "$n" -eq 0 ] || [ "$last_code" != "200" ]; then
  log "mutation error body: $(head -c 400 "$CLONE_ROOT/mut-body.json" 2>/dev/null || true)"
  fail_red "timed BoardCards write did not return HTTP 200 (last=$last_code n=$n)"
fi

# RYW: point-read immediately after 200.
ryw=0
q="$(curl_sock "$sock" /api/query -H 'Content-Type: application/json' -d "$read_body" 2>/dev/null || true)"
if printf '%s' "$q" | grep -q 'write-path-cow-probe'; then
  ryw=1
fi
log "ryw_after_200=$ryw"

# Phase dump from the full request-ops ring (cheap /api/status omits it).
status="$(curl_sock "$sock" "/api/status?recent=1" 2>/dev/null || true)"
printf '%s' "$status" >"$CLONE_ROOT/status.json"
phase_json="$(printf '%s' "$status" | jq -c '
  [.status.request_ops.recent[]? // .request_ops.recent[]? | select(
    ((.kind|tostring|ascii_downcase) | test("mutation"))
    and (.client == "write-path-cow-probe")
  )] | last // {}
' 2>/dev/null || echo '{}')"
printf '%s' "$phase_json" >"$phase_log"
persist_us="$(printf '%s' "$phase_json" | jq -r '.phases.persist_molecules_us // 0')"
sync_us="$(printf '%s' "$phase_json" | jq -r '.phases.sync_capture_us // 0')"
purge_us="$(printf '%s' "$phase_json" | jq -r '.phases.purge_barrier_us // 0')"
exclusive="$(printf '%s' "$phase_json" | jq -r '.phases.purge_commit_us // 0')"
unresolved="$(printf '%s' "$status" | jq -r '.status.unresolved_rows // .unresolved_rows // 0')"

persist_ms=$(( ${persist_us:-0} / 1000 ))
sync_ms=$(( ${sync_us:-0} / 1000 ))
purge_ms=$(( ${purge_us:-0} / 1000 ))

# T1 on the request if persist was more than a spawn handshake.
persist_mode="awaited"
if [ "${persist_ms:-0}" -lt 20 ]; then
  persist_mode="spawn-only"
fi
sync_mode="awaited"
if [ "${sync_ms:-0}" -lt 20 ]; then
  sync_mode="encode-only"
fi
purge_in_batch=0
if [ "${exclusive:-0}" -gt 0 ] || [ "${purge_ms:-0}" -ge 5 ]; then
  purge_in_batch=1
fi
exclusive_flag=0
if [ "${exclusive:-0}" -gt 1000 ]; then
  exclusive_flag=1
fi
log "phases persist_us=$persist_us sync_capture_us=$sync_us purge_barrier_us=$purge_us purge_commit_us=$exclusive"

ack_ms="$p50"
[ "$ack_ms" != "-1" ] || ack_ms="${ms:-0}"

jq -n \
  --argjson ack "${ack_ms:-0}" \
  --arg persist "$persist_mode" \
  --arg sync "$sync_mode" \
  --argjson purge "$purge_in_batch" \
  --argjson barrier "${purge_ms:-0}" \
  --argjson p50 "${p50:-0}" \
  --argjson p95 "${p95:-0}" \
  --argjson exclusive "$exclusive_flag" \
  --argjson ryw "$ryw" \
  --argjson unresolved "${unresolved:-0}" \
  --argjson persist_us "${persist_us:-0}" \
  --argjson sync_us "${sync_us:-0}" \
  --argjson purge_us "${purge_us:-0}" \
  '{
    ack_ms: $ack,
    persist_mode: $persist,
    sync_capture_mode: $sync,
    persist: $persist,
    sync_capture: $sync,
    purge_in_batch: $purge,
    purge_barrier_ms: $barrier,
    p50_ms: $p50,
    p95_ms: $p95,
    exclusive_purge: $exclusive,
    ryw: $ryw,
    unresolved_rows: $unresolved,
    persist_us: $persist_us,
    sync_capture_us: $sync_us,
    purge_barrier_us: $purge_us
  }' >"$sample_out"
cp "$sample_out" "$phase_log"
log "sample $(cat "$sample_out")"

# kanban list titles on the probe.
list_out="$(kanban_list_probe || true)"
printf '%s\n' "$list_out" >"$CLONE_ROOT/kanban-list.txt"
if ! printf '%s' "$list_out" | grep -q .; then
  warn "kanban list on probe returned empty"
fi

# Graceful restart: SIGTERM, drain, boot again, RYW still holds.
log "graceful SIGTERM of probe node"
kill -TERM "$CANDIDATE_PID" 2>/dev/null || true
wait "$CANDIDATE_PID" 2>/dev/null || true
CANDIDATE_PID=""
rm -f "$sock"
env -u SENTRY_DSN -u FOLD_SENTRY_DSN ${env_pairs[@]+"${env_pairs[@]}"} \
  "$LASTDBD_BIN" --data-dir "$copy" >>"$blog" 2>&1 &
CANDIDATE_PID=$!
uh2=""
for i in $(seq 1 120); do
  if [ -S "$sock" ]; then
    uh2="$(live_identity "$sock")"
    [ -n "$uh2" ] && break
  fi
  sleep 1
done
[ -n "$uh2" ] || fail_red "probe did not come back after SIGTERM"
graceful_ryw=0
q2="$(curl_sock "$sock" /api/query -H 'Content-Type: application/json' -d "$read_body" 2>/dev/null || true)"
if printf '%s' "$q2" | grep -q 'write-path-cow-probe'; then
  graceful_ryw=1
fi
log "graceful restart ryw=$graceful_ryw"

if [ "$DO_KILL9" -eq 1 ]; then
  log "optional kill -9 between T0 and T1 (named crash window, not RED)"
  echo "KILL9_WINDOW: ack may be lost between T0 and T1; catalog must still parse" >>"$CLONE_ROOT/kill9.log"
  kill -9 "$CANDIDATE_PID" 2>/dev/null || true
  CANDIDATE_PID=""
  env -u SENTRY_DSN -u FOLD_SENTRY_DSN ${env_pairs[@]+"${env_pairs[@]}"} \
    "$LASTDBD_BIN" --data-dir "$copy" >>"$blog" 2>&1 &
  CANDIDATE_PID=$!
  for i in $(seq 1 120); do
    [ -S "$sock" ] && [ -n "$(live_identity "$sock")" ] && break
    sleep 1
  done
  cat_ok=0
  schemas_after="$(curl_sock "$sock" /api/schemas 2>/dev/null || true)"
  if printf '%s' "$schemas_after" | grep -qi 'BoardCards'; then
    cat_ok=1
  fi
  echo "catalog_parses=$cat_ok" >>"$CLONE_ROOT/kill9.log"
  log "kill-9 catalog_parses=$cat_ok"
  if [ "$cat_ok" -ne 1 ]; then
    fail_red "kill -9 left BoardCards unparseable"
  fi
fi

LIVE_ID_AFTER="$(live_identity "$PRIMARY_SOCK")"
LIVE_PID_AFTER="$(live_pid)"
log "live identity after=$(printf '%s' "$LIVE_ID_AFTER" | cut -c1-12) pid=${LIVE_PID_AFTER:-none}"
if [ -n "$LIVE_ID_BEFORE" ] && [ -n "$LIVE_ID_AFTER" ] && [ "$LIVE_ID_BEFORE" != "$LIVE_ID_AFTER" ]; then
  fail_red "live socket identity changed ($LIVE_ID_BEFORE -> $LIVE_ID_AFTER)"
fi
if [ -n "$LIVE_PID_BEFORE" ] && [ -n "$LIVE_PID_AFTER" ] && [ "$LIVE_PID_BEFORE" != "$LIVE_PID_AFTER" ]; then
  warn "live PID changed ${LIVE_PID_BEFORE} -> ${LIVE_PID_AFTER}"
fi

# Candidate must not have written the probe slug into the live home.
live_q="$(curl_sock "$PRIMARY_SOCK" /api/query -H 'Content-Type: application/json' -d "$read_body" 2>/dev/null || true)"
if printf '%s' "$live_q" | grep -q 'write-path-cow-probe' && ! printf '%s' "$live_q" | grep -q 'write-path-cow-probe' ; then
  :
fi
# Stronger: the live home data-dir mtime of identity is not our concern; the
# probe slug must not appear on the live socket.
if printf '%s' "$live_q" | grep -q '"write-path-cow-probe"'; then
  fail_red "probe slug visible on the live socket — candidate wrote into ~/.lastdb"
fi

log "candidate --data-dir=$copy unresolved_rows=${unresolved:-0}"

set +e
classify_out="$(write_path_classify_json_file "$sample_out")"
classify_rc=$?
set -e
printf '%s\n' "$classify_out"
echo "CANDIDATE: $LASTDBD_BIN"
echo "DATA_DIR: $copy"
echo "P50_MS: $p50"
echo "P95_MS: $p95"
echo "PERSIST: $persist_mode"
echo "SYNC_CAPTURE: $sync_mode"
echo "PURGE_BARRIER_MS: $purge_ms"
echo "RYW: $ryw"
echo "GRACEFUL_RYW: $graceful_ryw"
echo "UNRESOLVED_ROWS: ${unresolved:-0}"
if [ "$classify_rc" -eq 0 ]; then
  echo "VERDICT: GREEN"
else
  echo "VERDICT: RED"
fi
exit "$classify_rc"
