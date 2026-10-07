#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh"
bash -n "$SCRIPT"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh
. "$SCRIPT"

TEST_ROOT="$(mktemp -d /private/tmp/lastdb-session-copy.XXXXXX)"
ACTIVE_PID=""
cleanup() {
  if [ -n "$ACTIVE_PID" ]; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

home="$TEST_ROOT/home"
copy="$TEST_ROOT/copy"
pid=999991
start_ts=12345
mkdir -p "$home/data/data"
printf 'identity fixture\n' >"$home/identity.key"
printf '{"paused":true}\n' >"$home/cloud_sync.json.paused"
printf 'one record\n' >"$home/data/data/record"

write_session() {
  printf '{"pid":%s,"start_ts":%s,"last_heartbeat_ts":%s}\n' \
    "$1" "$2" "$(( $2 + 1 ))" >"$home/current-session.json"
}
write_ledger() {
  printf '{"pid":%s,"start_ts":%s,"end_ts":%s,"exit":"%s"}\n' \
    "$1" "$2" "$(( $2 + 3 ))" "$3" >"$home/sessions.jsonl"
}
write_session "$pid" "$start_ts"
write_ledger "$pid" "$start_ts" clean
cp "$home/current-session.json" "$TEST_ROOT/old-session.json"

SUPERVISOR_LOADED=0
LIVE_SOCKET=0
lastdb_launchd_job_loaded() { [ "$SUPERVISOR_LOADED" -eq 1 ]; }
live_unix_socket_has_listener() { [ "$LIVE_SOCKET" -eq 1 ]; }

session_sha="$(verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test)"
[ -n "$session_sha" ] || { echo 'FAIL: clean stopped session had no hash' >&2; exit 1; }

SUPERVISOR_LOADED=1
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: loaded supervisor passed stopped session check' >&2; exit 1
fi
SUPERVISOR_LOADED=0
LIVE_SOCKET=1
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: live socket passed stopped session check' >&2; exit 1
fi
LIVE_SOCKET=0

sleep 30 &
ACTIVE_PID=$!
write_session "$ACTIVE_PID" "$start_ts"
write_ledger "$ACTIVE_PID" "$start_ts" clean
if verify_stopped_waiver_session "$home" "$ACTIVE_PID" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: live process passed stopped session check' >&2; exit 1
fi
kill "$ACTIVE_PID"
wait "$ACTIVE_PID" 2>/dev/null || true
ACTIVE_PID=""

write_session "$((pid + 1))" "$start_ts"
write_ledger "$pid" "$start_ts" clean
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: wrong session PID passed' >&2; exit 1
fi
write_session "$pid" "$((start_ts + 1))"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: wrong session start time passed' >&2; exit 1
fi
write_session "$pid" "$start_ts"
printf '{"pid":%s,"start_ts":%s,"last_heartbeat_ts":%s}\n' \
  "$pid" "$start_ts" "$((start_ts + 2))" >>"$home/current-session.json"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: two session documents passed' >&2; exit 1
fi
write_session "$pid" "$start_ts"

write_ledger "$pid" "$start_ts" shutdown_started
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: unclean ledger passed' >&2; exit 1
fi
write_ledger "$pid" "$start_ts" clean
printf '{"pid":%s,"start_ts":%s,"end_ts":%s,"exit":"clean"}\n' \
  "$pid" "$start_ts" "$((start_ts + 4))" >>"$home/sessions.jsonl"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: duplicate ledger row passed' >&2; exit 1
fi
write_ledger "$pid" "$start_ts" clean
printf 'null\n' >>"$home/sessions.jsonl"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: null ledger row passed' >&2; exit 1
fi
write_ledger "$pid" "$start_ts" clean
printf '{}\n' >>"$home/sessions.jsonl"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: empty ledger row passed' >&2; exit 1
fi
write_ledger "$pid" "$start_ts" clean
printf '{bad json\n' >>"$home/sessions.jsonl"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null 2>&1; then
  echo 'FAIL: malformed ledger line passed' >&2; exit 1
fi
write_ledger "$pid" "$start_ts" clean

unlink "$home/current-session.json"
ln -s "$TEST_ROOT/old-session.json" "$home/current-session.json"
if verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test >/dev/null; then
  echo 'FAIL: symlink session passed' >&2; exit 1
fi
unlink "$home/current-session.json"
write_session "$pid" "$start_ts"
session_sha="$(verify_stopped_waiver_session "$home" "$pid" "$start_ts" gui/501/test)"

decision=decision-2026-10-06-cloud-sync-rescue-risk-acceptance
python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py" \
  --home "$home" --pid "$pid" --start-ts "$start_ts" \
  --copy-path "$copy" --decision-slug "$decision"
timeout_bin="$(command -v gtimeout || command -v timeout)"
before_free="$(free_kib "$home")"
if ! copy_stopped_home "$home" "$copy" "$timeout_bin" "$before_free" waiver "$session_sha"; then
  cmp -s "$home/current-session.json" "$TEST_ROOT/old-session.json" \
    || { echo 'FAIL: copy changed the primary session bytes' >&2; exit 1; }
  echo 'FAIL: valid stopped session copy was rejected' >&2; exit 1
fi
cmp -s "$home/current-session.json" "$TEST_ROOT/old-session.json" \
  || { echo 'FAIL: copy changed the primary session bytes' >&2; exit 1; }
[ ! -e "$copy/current-session.json" ] && [ ! -L "$copy/current-session.json" ] \
  || { echo 'FAIL: staged copy retained a live session marker' >&2; exit 1; }

cat >"$TEST_ROOT/corrupt-stage-timeout.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_TIMEOUT_BIN" "$@"
if [ "${4:-}" = cp ]; then
  printf 'altered staged marker\n' >"$7/current-session.json"
fi
SH
chmod +x "$TEST_ROOT/corrupt-stage-timeout.sh"
export REAL_TIMEOUT_BIN="$timeout_bin"
if copy_stopped_home "$home" "$TEST_ROOT/altered-stage-copy" \
  "$TEST_ROOT/corrupt-stage-timeout.sh" "$before_free" waiver "$session_sha" \
  >"$TEST_ROOT/altered-stage.out" 2>&1; then
  echo 'FAIL: altered staged marker passed' >&2; exit 1
fi
cmp -s "$home/current-session.json" "$TEST_ROOT/old-session.json" \
  || { echo 'FAIL: altered staged copy changed primary session bytes' >&2; exit 1; }

if copy_stopped_home "$home" "$TEST_ROOT/bad-sha-copy" "$timeout_bin" \
  "$before_free" waiver 0000000000000000000000000000000000000000000000000000000000000000 \
  >"$TEST_ROOT/bad-sha.out" 2>&1; then
  echo 'FAIL: wrong source or staged marker hash passed' >&2; exit 1
fi
cmp -s "$home/current-session.json" "$TEST_ROOT/old-session.json" \
  || { echo 'FAIL: failed copy changed the primary session bytes' >&2; exit 1; }

printf '{"version":1,"pid":%s,"start_ts":%s,"flush_ok":true}\n' \
  "$pid" "$start_ts" >"$home/.shutdown_flush_ready"
if copy_stopped_home "$home" "$TEST_ROOT/receipt-copy" "$timeout_bin" \
  "$before_free" receipt >"$TEST_ROOT/receipt.out" 2>&1; then
  echo 'FAIL: receipt mode accepted a retained session marker' >&2; exit 1
fi
cmp -s "$home/current-session.json" "$TEST_ROOT/old-session.json" \
  || { echo 'FAIL: receipt rejection changed the primary session bytes' >&2; exit 1; }

printf 'PASS: stopped waiver checks old session and removes only staged marker\n'
