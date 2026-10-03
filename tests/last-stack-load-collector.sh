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
  # A bounded host-helper read that lost its race is recorded in the sample, so a
  # failure whose real cause is an empty host sample says so here instead of
  # sending the reader to the node.
  ls "$T/mon"/load-*.jsonl >/dev/null 2>&1 && {
    echo "--- last sample .host.degraded: $(tail -n 1 "$T/mon"/load-*.jsonl | jq -c '.host.degraded // "none"')" >&2
  }
  ls -la "$T/mon" >&2 2>/dev/null || true
  exit 1
}

# A `lastdb` that hangs, like the real CLI on a saturated node.
printf '#!/bin/sh\nsleep 30\n' >"$T/lastdb-hang"
printf '#!/bin/sh\nprintf "  1. app=kanban verb=query count=90 avg=44ms p95=- max=900ms err=1 body_sum=1B\\n  2. app=loom verb=query count=10 avg=25ms p95=- max=50ms err=0 body_sum=1B\\n"\n' >"$T/lastdb-ok"
chmod +x "$T/lastdb-hang" "$T/lastdb-ok"

export LOAD_MON_ALERT_SWAP_MB=999999999 LOAD_MON_ALERT_LOAD1=999999 LOAD_MON_ALERT_HOG_PCT=999999
export LOAD_MON_WRITES=0  # a fixture must not scan the real home; 6b turns it on for a temp root
export LOAD_MON_DATA_ROOT="$T/nodata" LOAD_MON_NOTIFY=0 LOAD_MON_DEADLINE_SEC=1 LOAD_MON_DIR="$T/mon" LOAD_MON_SOCKET="$S/n.sock"
# Same rule as LOAD_MON_WRITES above, for every alert rule that reads this
# host's real state -- launchd plists, host-track's observation caches, the
# routines daemon's logs. ONE switch, not a knob per rule.
#
# The previous shape was a knob per rule plus the allowlist loop below, and it
# did not hold. Two rules were isolated here by hand, each after it had already
# broken this fixture's alert COUNTS, and the loop could only check the knobs
# somebody had remembered to add to it. Measured 2026-10-03 on main tip
# 514043dd8 with both knobs set and the loop passing: evaluate_alerts was still
# opening this host's live 133 MB ~/.routines/daemon/routinesd.err.log through a
# third knob, and the collector turned out to have SEVEN such defaults. The
# counts here were green only because the scheduler happened to be dispatching.
# CI never saw any of it -- a runner has no launchd plist, no observation cache
# and no daemon log -- so the gate was red for agents on this host and green on
# the runner, which is how a fleet learns to ignore its own gate.
#
# papercut-load-collector-alert-rules-read-real-host-state-with-no-hermetic-switch-so-each-new-rule-breaks-the-count-fixtures-20261003
export LOAD_MON_HERMETIC=1
[ "$LOAD_MON_NOTIFY" = "0" ] && [ "$LOAD_MON_DEADLINE_SEC" = "1" ] || { echo "test env must keep NOTIFY=0 (a fixture must never post to live Situations)" >&2; exit 1; }
# The switch replaces the per-knob allowlist that used to live here. It is one
# assertion that covers every host-state read, present and future, instead of a
# list that silently passes the knob nobody added to it.
[ "${LOAD_MON_HERMETIC:-}" = "1" ] || { echo "test env must keep LOAD_MON_HERMETIC=1 (a fixture must never read this host's real launchd, host-track or routines state)" >&2; exit 1; }


# The host sample must not depend on node access or host-tool permissions.
# Supply deterministic host helpers because some runners deny their real ps and
# sysctl even though the collector must still record a non-empty host sample.
mkdir -p "$T/hostbin"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "vm.swapusage: total = 1.00M used = 1.00M free = 0.00M"' >"$T/hostbin/sysctl"
printf '%s\n' '#!/bin/sh' 'case "$*" in *command=*) exit 0;; esac' 'printf "%s\\n" "123 1.0 1024 fixture-worker"' >"$T/hostbin/ps"
chmod +x "$T/hostbin/sysctl" "$T/hostbin/ps"
export PATH="$T/hostbin:$PATH"

last_field() { tail -n 1 "$T/mon"/load-*.jsonl | jq -r "$1"; }

# 1. no socket -> state down, still writes a full host sample
#
# `ps` runs under a 3s bound and the stub below is a /bin/sh spawn, so on a loaded
# runner that read can lose its race and leave `top` empty. That is an environment
# condition, not a product defect, and it used to red this gate with an assertion
# that blamed the node (papercut-last-stack-load-collector-sh-fails-under-host-load-
# on-a-pristine-tree-with-a-misleading-assertion-20261002). Retry the lost race, and
# when it persists, fail with the reason the sample now records. State is reset
# before each attempt so a retry cannot push an alert counter over its threshold and
# break case 4's "no alert yet" assertion.
export LOAD_MON_LASTDB="$T/lastdb-ok"
sample_with_host_top() {
  local i
  for i in 1 2 3; do
    printf '{}' >"$T/mon/.state.json" 2>/dev/null || true
    "$BIN" sample
    [ "$(last_field '.host.top | length')" -gt 0 ] && return 0
  done
  return 1
}
mkdir -p "$T/mon"
sample_with_host_top || fail "host sample top is empty after 3 passes; degraded reads: $(last_field '(.host.degraded // "none - nothing recorded a lost race, so this is a real gap") | tojson')"
[ "$(last_field .node.status.state)" = "down" ] || fail "no socket should be down"

# 1b. ps/sysctl/lastdb not runnable (sandboxed runner): still a sample, never a gap
PY="$(command -v python3)"
PATH="$T/nopath" LOAD_MON_LASTDB=lastdb-missing "$PY" "$BIN" sample
[ "$(last_field .node.status.state)" = "down" ] || fail "sample must be written with no runnable helpers"
[ ! -s "$T/mon/collector-errors.log" ] || fail "missing helpers are not collector errors"
# ... but they must not be silent either: an empty top has to say why.
[ "$(last_field '.host.degraded.ps')" = "not runnable" ] || fail "an unrunnable ps must be named in the sample, got: $(last_field '.host.degraded // "nothing"')"

# 1c. a bounded host read that hits its DEADLINE is recorded, not discarded.
# This is the condition that reds this gate under load; it is reproduced here with
# a stub that is slower than the 3s bound instead of by waiting for a loaded host.
mkdir -p "$T/slowbin"
printf '%s\n' '#!/bin/sh' 'sleep 4' 'printf "%s\\n" "123 1.0 1024 fixture-worker"' >"$T/slowbin/ps"
cp "$T/hostbin/sysctl" "$T/slowbin/sysctl"
chmod +x "$T/slowbin/ps" "$T/slowbin/sysctl"
printf '{}' >"$T/mon/.state.json"  # this case is about the sample field, not an alert
PATH="$T/slowbin:$PATH" "$BIN" sample
[ "$(last_field '.host.top | length')" = "0" ] || fail "a ps slower than its bound cannot produce a top"
[ "$(last_field '.host.degraded.ps')" = "deadline after 3s" ] || fail "a deadlined ps read must name its bound, got: $(last_field '.host.degraded // "nothing"')"
[ ! -s "$T/mon/collector-errors.log" ] || fail "a bounded read losing its race is a sample field, not a collector error"
"$BIN" report --minutes 5 | grep -q "degraded host reads" || fail "report must surface a degraded host read; an empty top is not an idle host"

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
# The claims in 4 and 5 are about what THIS pass does, so they count rows rather
# than read the whole alert history. Reading the history made them inherit every
# earlier case: cases 1 and 1b are 2 down passes against the default NODE_CONSEC=3,
# which left one pass of headroom, so any extra non-ok pass above fired
# node_unresponsive and red "one bad pass must not alert" on a loaded runner.
alert_rows() { [ -e "$T/mon/alerts.jsonl" ] && wc -l <"$T/mon/alerts.jsonl" | tr -d ' ' || echo 0; }
ALERTS0="$(alert_rows)"
START=$SECONDS
"$BIN" sample
ELAPSED=$((SECONDS - START))
[ "$ELAPSED" -le 6 ] || fail "pass took ${ELAPSED}s under a hung node; the deadline is not hard"
[ "$(last_field .node.status.state)" = "busy" ] || fail "hung node should be busy"
[ "$(last_field .node.ops.state)" = "busy" ] || fail "hung CLI should be busy"
[ "$(alert_rows)" = "$ALERTS0" ] || fail "one bad pass must not alert (threshold 2)"

# 5. second bad pass alerts; third is inside the cooldown and does not repeat it
"$BIN" sample
[ "$(tail -n 1 "$T/mon/alerts.jsonl" | jq -r .alert)" = "node_unresponsive" ] || fail "second bad pass should alert"
[ "$(alert_rows)" = "$((ALERTS0 + 1))" ] || fail "second bad pass should add exactly one alert"
ALERTS1="$(alert_rows)"
"$BIN" sample
[ "$(alert_rows)" = "$ALERTS1" ] || fail "cooldown should suppress a repeat alert"
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
# Wait on the LAST file the fake curl writes, not the first: it copies the body and
# only then writes the args, so waiting on the body and grepping the args is a race
# that a loaded runner loses.
for _ in $(seq 1 100); do [ -s "$T/curl.args" ] && [ -s "$T/curl.body" ] && break; sleep 0.2; done
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

# 5f. a push whose helper needs a tool outside the launchd PATH must still arrive (ra -> bun)
mkdir -p "$T/toolbin"; printf '#!/bin/sh\necho ok >"%s/bun.ran"\n' "$T" >"$T/toolbin/needtool"; chmod +x "$T/toolbin/needtool"
printf '#!/bin/sh\nexec needtool\n' >"$T/ra-tool"; chmod +x "$T/ra-tool"
printf '{}' >"$T/mon/.state.json"
LOAD_MON_EXTRA_PATH="$T/toolbin" LOAD_MON_PHONE=1 LOAD_MON_RA="$T/ra-tool" LOAD_MON_ALERT_LOAD1=0 LOAD_MON_ALERT_LOAD_CONSEC=1 "$BIN" sample
for _ in $(seq 1 50); do [ -s "$T/bun.ran" ] && break; sleep 0.2; done
[ -s "$T/bun.ran" ] || fail "push helper must find tools on the extra PATH"

# 6. report runs and counts the states
OUT="$("$BIN" report --minutes 5 --json)"
[ "$(printf '%s' "$OUT" | jq -r '.node_states.busy')" = "3" ] || fail "report should count 3 busy passes"
printf '%s' "$OUT" | jq -e '.cpu_by_process | length > 0' >/dev/null || fail "report needs CPU by process"

# 6b. write-rate scan: first pass primes the marker, later passes count files written since
mkdir -p "$T/wr/hot/a" "$T/wr/cold"
export LOAD_MON_WRITE_ROOTS="$T/wr"
"$BIN" writes
sleep 1.1
for i in 1 2 3; do echo x >"$T/wr/hot/a/f$i"; done
echo y >"$T/wr/cold/g"
"$BIN" writes
wf() { tail -n 1 "$T/mon"/writes-*.jsonl | jq -r "$1"; }
[ "$(wf '.roots["'"$T"'/wr"].n')" = "4" ] || fail "write scan should count 4 new files"
[ "$(wf '.roots["'"$T"'/wr"].top[0][0]')" = "hot/a" ] || fail "busiest subdir should be hot/a"
"$BIN" report --minutes 5 | grep -q "file writes/s by root" || fail "report should show writes/s"
LOAD_MON_WRITE_ROOTS="/nonexistent-root-x" "$BIN" writes
[ "$(wf '.roots["/nonexistent-root-x"].state')" = "skipped" ] || fail "missing root should be skipped, not fail"
# sample never waits for the scan: a hanging find must not stretch the pass
rm -f "$T/mon/.write-marker"; LOAD_MON_WRITES=1 LOAD_MON_WRITE_EVERY_SEC=0 "$BIN" sample
[ "$(last_field .collector_ms)" -lt 3000 ] || fail "sample must not wait on the write scan"
[ -e "$T/mon/.write-scan.lock" ] || [ -e "$T/mon/.write-marker" ] || fail "sample should start a detached scan"
unset LOAD_MON_WRITE_ROOTS

# 7. rotation deletes files past the retention window
touch -t 202001010000 "$T/mon/load-20200101.jsonl"
LOAD_MON_RETAIN_DAYS=14 "$BIN" sample
[ ! -e "$T/mon/load-20200101.jsonl" ] || fail "old file should rotate out"

echo "PASS last-stack-load-collector"
