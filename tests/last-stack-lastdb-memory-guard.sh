#!/usr/bin/env bash
# last-stack-lastdb-memory-guard fixtures.
#
# The guard is a process-killer aimed at the primary brain, so the properties
# under test are mostly about when it does NOT fire:
#   - default enforcement is still rss (the metric change must not smuggle in a
#     behaviour change while the limit policy is undecided)
#   - the blind spot — footprint over the ceiling, rss under it — is logged and
#     NOT acted on
#   - footprint enforcement refuses to fall back to rss when the node is
#     unreachable, because that silently restores the 6.7x blind spot
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUARD="$ROOT/bin/last-stack-lastdb-memory-guard"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# The guard pins its own PATH under launchd; point that pin at the shims.
export LASTDBD_GUARD_PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$tmp/bin" "$tmp/home/.lastdb/data"
export HOME="$tmp/home"
export LASTDBD_PRIMARY_HOME="$tmp/home/.lastdb"
LOG="$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.log"

FAKE_PID=4242

# Fake ps covering every form the guard uses. RSS is fed via FAKE_RSS_KB.
cat >"$tmp/bin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "-Ao pid=,comm=")   printf '%s /opt/lastdb/bin/lastdbd\n' "${FAKE_PID:-4242}" ;;
  *"-o args="*)       printf '/opt/lastdb/bin/lastdbd\n' ;;
  "eww -p "*)         printf 'PID TTY TIME CMD LASTDB_HOME=%s\n' "$LASTDBD_PRIMARY_HOME" ;;
  *"-o rss="*)        printf '%s\n' "${FAKE_RSS_KB:-0}" ;;
  *"-o command="*)    printf '/opt/lastdb/bin/lastdbd\n' ;;
  *)                  exit 1 ;;
esac
SH

# Fake curl: serves /api/status unless FAKE_NODE_DOWN=1.
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_NODE_DOWN:-0}" = "1" ]; then exit 7; fi
printf '{"status":{"rss_bytes":%s,"phys_footprint_bytes":%s,"phys_footprint_peak_bytes":%s}}' \
  "${FAKE_RSS_BYTES:-0}" "${FAKE_FOOTPRINT_BYTES:-0}" "${FAKE_PEAK_BYTES:-0}"
SH

# Fake sysctl for vm.swapusage.
cat >"$tmp/bin/sysctl" <<'SH'
#!/usr/bin/env bash
printf 'total = 8192.00M  used = %s.00M  free = 100.00M\n' "${FAKE_SWAP_MB:-10}"
SH

# kill/launchctl record what the guard tried to do instead of doing it.
cat >"$tmp/bin/kill" <<'SH'
#!/usr/bin/env bash
# `kill -0` is a liveness probe; report dead so the guard does not sleep 10s.
case "${1:-}" in
  -0) exit 1 ;;
esac
printf 'kill %s\n' "$*" >>"$FAKE_ACTION_LOG"
SH

cat >"$tmp/bin/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$FAKE_ACTION_LOG"
case "${1:-}" in
  list)  printf '%s\t0\tcom.example.lastdbd-primary\n' "${FAKE_PID:-4242}" ;;
  print) exit 0 ;;
esac
SH

chmod +x "$tmp/bin/"*
export FAKE_PID FAKE_ACTION_LOG="$tmp/actions.log"

MB=1048576
reset() {
  : >"$FAKE_ACTION_LOG"
  rm -f "$LOG" "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.state"
}
restarted() { grep -q 'launchctl kickstart' "$FAKE_ACTION_LOG" 2>/dev/null; }

# --- 1. invalid metric is rejected loudly rather than defaulting -------------
reset
if LASTDBD_GUARD_METRIC=bogus "$GUARD" >/dev/null 2>&1; then
  fail "invalid LASTDBD_GUARD_METRIC should exit non-zero"
fi

# --- 2. default enforcement is rss: footprint way over, rss under -> no kill -
# This is the whole point of the change landing in two halves. 8.7 GiB
# footprint against a 6 GiB ceiling must NOT fire while the metric is rss.
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((8700 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 under rss enforcement"

restarted && fail "rss enforcement must not restart when only footprint is over"
grep -q 'metric=rss' "$LOG" || fail "log should record the enforced metric"
grep -q 'footprint_mb=8700' "$LOG" || fail "log should carry the footprint gauge"
grep -q 'peak_mb=11110' "$LOG" || fail "log should carry the footprint peak"
grep -q 'rss_mb=1500' "$LOG" || fail "log should still carry rss"
grep -q 'WARN blind_spot' "$LOG" || fail "blind spot must be logged when footprint >= limit under rss"

# --- 3. no blind-spot warning when footprint is genuinely under the ceiling --
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((3000 * MB)) \
FAKE_PEAK_BYTES=$((3200 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 when both gauges are under"
grep -q 'blind_spot' "$LOG" && fail "must not cry blind spot when footprint is under the limit"

# --- 4. footprint enforcement fires on the true gauge ------------------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((8700 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=footprint \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a restart"
restarted || fail "footprint enforcement must restart when footprint exceeds the limit"
grep -q 'OVER_LIMIT.*metric=footprint.*enforced_mb=8700' "$LOG" \
  || fail "over-limit line should name the footprint gauge and reading"

# --- 5. footprint enforcement declines rather than falling back to rss -------
# Falling back would silently restore the blind spot the policy closed.
reset
FAKE_NODE_DOWN=1 \
FAKE_RSS_KB=$((1500 * 1024)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=footprint \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 when it declines to enforce"
restarted && fail "must not restart on an unavailable footprint reading"
grep -q 'footprint_unavailable' "$LOG" || fail "declining to enforce must be logged"

# --- 6. rss enforcement still fires on rss, exactly as before ----------------
reset
FAKE_RSS_KB=$((7000 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after an rss restart"
restarted || fail "rss enforcement must still fire when rss exceeds the limit"

# --- 7. node unreachable under rss enforcement: still guards on rss ----------
reset
FAKE_NODE_DOWN=1 \
FAKE_RSS_KB=$((7000 * 1024)) \
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 with node unreachable"
restarted || fail "rss enforcement must not depend on the status socket"
grep -q 'footprint_mb=unavailable' "$LOG" || fail "unavailable footprint should be stated, not omitted"

printf 'PASS: last-stack-lastdb-memory-guard\n'
