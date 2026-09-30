#!/usr/bin/env bash
# last-stack-load-collector: node state is a VALUE under a hard deadline, the
# pass never outlives that deadline, and alerts never wait on LastDB.
# North Star: north-star-lastdb-load-monitoring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-load-collector"
FAKE="$ROOT/tests/fixtures/load-collector-fake-node.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/load-collector-test.XXXXXX")"
# AF_UNIX paths cap near 104 bytes; a long CI TMPDIR must not break the socket.
S="$(mktemp -d /tmp/lcs.XXXXXX)"
FAKE_PID=""
cleanup() { [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null || true; rm -rf "$S"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  [ ! -f "$T/mon/collector-errors.log" ] || { echo "--- collector-errors.log" >&2; cat "$T/mon/collector-errors.log" >&2; }
  ls -la "$T/mon" >&2 2>/dev/null || true
  exit 1
}

# A `lastdb` that hangs, like the real CLI on a saturated node.
printf '#!/bin/sh\nsleep 30\n' >"$T/lastdb-hang"
printf '#!/bin/sh\nprintf "  1. app=kanban verb=query count=90 avg=44ms p95=- max=900ms err=1 body_sum=1B\\n  2. app=loom verb=query count=10 avg=25ms p95=- max=50ms err=0 body_sum=1B\\n"\n' >"$T/lastdb-ok"
chmod +x "$T/lastdb-hang" "$T/lastdb-ok"

export LOAD_MON_ALERT_SWAP_MB=999999999 LOAD_MON_ALERT_LOAD1=999999 LOAD_MON_ALERT_HOG_PCT=999999
export LOAD_MON_NOTIFY=0 LOAD_MON_DEADLINE_SEC=1 LOAD_MON_DIR="$T/mon" LOAD_MON_SOCKET="$S/n.sock"
[ "$LOAD_MON_NOTIFY" = "0" ] && [ "$LOAD_MON_DEADLINE_SEC" = "1" ] || { echo "test env must keep NOTIFY=0 (a fixture must never post to live Situations)" >&2; exit 1; }

last_field() { tail -n 1 "$T/mon"/load-*.jsonl | jq -r "$1"; }

# 1. no socket -> state down, still writes a full host sample
export LOAD_MON_LASTDB="$T/lastdb-ok"
"$BIN" sample
[ "$(last_field .node.status.state)" = "down" ] || fail "no socket should be down"
[ "$(last_field '.host.top | length')" -gt 0 ] || fail "host sample must not depend on the node"

# 1b. ps/sysctl/lastdb not runnable (sandboxed runner): still a sample, never a gap
PY="$(command -v python3)"
PATH="$T/nopath" LOAD_MON_LASTDB=lastdb-missing "$PY" "$BIN" sample
[ "$(last_field .node.status.state)" = "down" ] || fail "sample must be written with no runnable helpers"
[ ! -s "$T/mon/collector-errors.log" ] || fail "missing helpers are not collector errors"

# 2. healthy node -> ok, ops rows parsed and sorted by count
python3 "$FAKE" "$S/n.sock" ok & FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$S/n.sock" ] && break; sleep 0.2; done
"$BIN" sample
[ "$(last_field .node.status.state)" = "ok" ] || fail "healthy node should be ok"
[ "$(last_field '.node.ops.rows[0][0]')" = "kanban" ] || fail "ops rows should sort by count"
kill "$FAKE_PID"; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""

# 3. shedding node -> the 503 error text is recorded
python3 "$FAKE" "$S/n.sock" shed & FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$S/n.sock" ] && break; sleep 0.2; done
"$BIN" sample
[ "$(last_field .node.status.state)" = "shedding" ] || fail "503 should be shedding"
[ "$(last_field .node.status.reason)" = "uds_worker_queue_full" ] || fail "shed reason should be recorded"
kill "$FAKE_PID"; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""

# 4. hung node + hung CLI -> busy, and the pass ends near the deadline, not at 30s
python3 "$FAKE" "$S/n.sock" hang & FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$S/n.sock" ] && break; sleep 0.2; done
export LOAD_MON_LASTDB="$T/lastdb-hang" LOAD_MON_ALERT_NODE_CONSEC=2
printf '{}' >"$T/mon/.state.json"  # earlier passes left a bad-pass count
START=$SECONDS
"$BIN" sample
ELAPSED=$((SECONDS - START))
[ "$ELAPSED" -le 6 ] || fail "pass took ${ELAPSED}s under a hung node; the deadline is not hard"
[ "$(last_field .node.status.state)" = "busy" ] || fail "hung node should be busy"
[ "$(last_field .node.ops.state)" = "busy" ] || fail "hung CLI should be busy"
[ ! -e "$T/mon/alerts.jsonl" ] || fail "one bad pass must not alert (threshold 2)"

# 5. second bad pass alerts; third is inside the cooldown and does not repeat it
"$BIN" sample
[ "$(jq -r .alert "$T/mon/alerts.jsonl")" = "node_unresponsive" ] || fail "second bad pass should alert"
"$BIN" sample
[ "$(wc -l <"$T/mon/alerts.jsonl" | tr -d ' ')" = "1" ] || fail "cooldown should suppress a repeat alert"
kill "$FAKE_PID"; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""

# 5b. vitals: footprint and sync-degraded alerts fire from /api/status vitals
python3 "$FAKE" "$S/n.sock" ok & FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$S/n.sock" ] && break; sleep 0.2; done
export LOAD_MON_LASTDB="$T/lastdb-ok" LOAD_MON_ALERT_FOOTPRINT_CONSEC=2 LOAD_MON_ALERT_SYNC_CONSEC=2
printf '{}' >"$T/mon/.state.json"
"$BIN" sample; "$BIN" sample
[ "$(last_field .node.status.vitals.fp_mb)" = "14336" ] || fail "vitals fp_mb missing"
grep -q lastdbd_footprint_high "$T/mon/alerts.jsonl" || fail "footprint alert should fire"
grep -q lastdb_sync_degraded "$T/mon/alerts.jsonl" || fail "sync degraded alert should fire"
"$BIN" report --minutes 5 | grep -q "node vitals" || fail "report should print node vitals"
kill "$FAKE_PID"; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""

# 5c. host alerts and the phone channel: a fake `ra` records what would be pushed
printf '#!/bin/sh\necho "$@" >>"%s/ra.log"\n' "$T" >"$T/ra"; chmod +x "$T/ra"
printf '{}' >"$T/mon/.state.json"
LOAD_MON_PHONE=1 LOAD_MON_RA="$T/ra" LOAD_MON_ALERT_LOAD1=0 LOAD_MON_ALERT_LOAD_CONSEC=1 "$BIN" sample
grep -q host_load_high "$T/mon/alerts.jsonl" || fail "host load alert should fire"
for _ in $(seq 1 100); do [ -s "$T/ra.log" ] && break; sleep 0.2; done
grep -q "LastDB load: host load1" "$T/ra.log" || fail "alert should reach ra notify"

# 5d. Sentry: a fake curl records the envelope; the DSN comes from an override
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in @*) cp "${a#@}" "%s/curl.body";; esac; done\nprintf "%%s\\n" "$@" >"%s/curl.args"\n' "$T" "$T" >"$T/curl"; chmod +x "$T/curl"
printf '{}' >"$T/mon/.state.json"
LOAD_MON_SENTRY=1 LOAD_MON_CURL="$T/curl" LOAD_MON_SENTRY_DSN="https://abc123@o1.ingest.sentry.io/42" \
  LOAD_MON_ALERT_LOAD1=0 LOAD_MON_ALERT_LOAD_CONSEC=1 "$BIN" sample
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/curl.body" ] && break; sleep 0.2; done
grep -q "https://o1.ingest.sentry.io/api/42/envelope/" "$T/curl.args" || fail "sentry envelope URL wrong"
grep -q "sentry_key=abc123" "$T/curl.args" || fail "sentry key missing"
sed -n 3p "$T/curl.body" | jq -e '.tags.alert == "host_load_high"' >/dev/null || fail "sentry event should carry the alert name"

# 5e. every push leaves a delivery row with its exit code; a failing channel is rc != 0
for _ in $(seq 1 50); do [ "$(jq -s '[.[] | select(.channel=="phone" and .rc==0)] | length' "$T/mon/delivery.jsonl" 2>/dev/null)" -ge 1 ] && break; sleep 0.2; done
jq -se 'any(.[]; .channel=="phone" and .rc==0 and .alert=="host_load_high")' "$T/mon/delivery.jsonl" >/dev/null || fail "phone delivery row missing"
jq -se 'any(.[]; .channel=="sentry" and .rc==0)' "$T/mon/delivery.jsonl" >/dev/null || fail "sentry delivery row missing"
printf '#!/bin/sh\nexit 7\n' >"$T/ra-bad"; chmod +x "$T/ra-bad"
printf '{}' >"$T/mon/.state.json"
LOAD_MON_PHONE=1 LOAD_MON_RA="$T/ra-bad" LOAD_MON_ALERT_LOAD1=0 LOAD_MON_ALERT_LOAD_CONSEC=1 "$BIN" sample
for _ in $(seq 1 50); do jq -se 'any(.[]; .rc==7)' "$T/mon/delivery.jsonl" >/dev/null 2>&1 && break; sleep 0.2; done
jq -se 'any(.[]; .channel=="phone" and .rc==7)' "$T/mon/delivery.jsonl" >/dev/null || fail "failed push should record its rc"
"$BIN" report --minutes 5 | grep -q "alert delivery: .*failed" || fail "report should show delivery failures"

# 6. report runs and counts the states
OUT="$("$BIN" report --minutes 5 --json)"
[ "$(printf '%s' "$OUT" | jq -r '.node_states.busy')" = "3" ] || fail "report should count 3 busy passes"
printf '%s' "$OUT" | jq -e '.cpu_by_process | length > 0' >/dev/null || fail "report needs CPU by process"

# 7. rotation deletes files past the retention window
touch -t 202001010000 "$T/mon/load-20200101.jsonl"
LOAD_MON_RETAIN_DAYS=14 "$BIN" sample
[ ! -e "$T/mon/load-20200101.jsonl" ] || fail "old file should rotate out"

echo "PASS last-stack-load-collector"
