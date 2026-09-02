#!/usr/bin/env bash
# last-stack-lastdb-memory-guard fixtures.
#
# The guard is a process-killer aimed at the primary brain, so the properties
# under test are mostly about when it does NOT fire:
#   - default enforcement is footprint at the ratified 16 GiB limit
#   - steady-state footprint below that limit causes no action
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
export LASTDBD_GUARD_RESTART_WAIT_SEC=2
LOG="$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.log"
EVENT_LOG="$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard-events.jsonl"

FAKE_PID=4242

# Fake ps covering every form the guard uses. RSS is fed via FAKE_RSS_KB.
cat >"$tmp/bin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "-Ao pid=,comm=")
    pid="${FAKE_PID:-4242}"
    if grep -q 'launchctl kickstart' "$FAKE_ACTION_LOG" 2>/dev/null; then pid=$((pid + 1)); fi
    printf '%s /opt/lastdb/bin/lastdbd\n' "$pid"
    ;;
  *"-o args="*)       printf '/opt/lastdb/bin/lastdbd\n' ;;
  "eww -p "*)         printf 'PID TTY TIME CMD LASTDB_HOME=%s\n' "$LASTDBD_PRIMARY_HOME" ;;
  *"-o rss="*)        printf '%s\n' "${FAKE_RSS_KB:-0}" ;;
  *"-o command="*)    printf '/opt/lastdb/bin/lastdbd\n' ;;
  *)                  exit 1 ;;
esac
SH

# Fake curl: serves status and the bounded boot-identity route unless the node
# is unavailable.
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_NODE_DOWN:-0}" = "1" ]; then exit 7; fi
case "$*" in
  *"/api/system/boot-identity"*)
    boot_pid="${FAKE_BOOT_PID:-${FAKE_PID:-4242}}"
    if [ -z "${FAKE_BOOT_PID:-}" ] && grep -q 'launchctl kickstart' "$FAKE_ACTION_LOG" 2>/dev/null; then
      boot_pid=$((boot_pid + 1))
    fi
    printf '{"pid":%s,"process_start_ts":%s,"build":"%s","restart_cause":"%s"}' \
      "$boot_pid" "${FAKE_BOOT_START:-1234}" \
      "${FAKE_BOOT_BUILD:-0.0.0-test}" "${FAKE_BOOT_CAUSE:-initial}"
    exit 0
    ;;
esac
printf '{"status":{"rss_bytes":%s,"phys_footprint_bytes":%s,"phys_footprint_peak_bytes":%s,"process_start_ts":%s,"build":{"version":"%s"}}}' \
  "${FAKE_RSS_BYTES:-0}" "${FAKE_FOOTPRINT_BYTES:-0}" "${FAKE_PEAK_BYTES:-0}" \
  "${FAKE_START_TS:-1234}" "${FAKE_BUILD:-0.0.0-test}"
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

# Situations shim. It must reject exactly what the real CLI rejects, or a guard
# bug survives a green suite: the 2026-08-30 attribution fix passed CI while
# every live notice was still rejected, because this shim only checked --actor.
# Real rule, situations src/record.ts: SLUG_RE = /^[a-z0-9][a-z0-9_-]*$/, and
# validateSlug throws invalid_slug before the write.
cat >"$tmp/bin/situations" <<'SH'
#!/usr/bin/env bash
printf 'situations %s\n' "$*" >>"$FAKE_ACTION_LOG"
slug=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--slug" ]; then slug="$arg"; fi
  prev="$arg"
done
if [ -n "$slug" ] && ! printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
  echo "Invalid slug \"$slug\"." >&2
  echo 'hint: Use lowercase letters, digits, hyphens, and underscores.' >&2
  exit 2
fi
case " $* " in
  *" --actor agent:lastdb-memory-guard "*) ;;
  *) echo "unexpected actor" >&2; exit 2 ;;
esac
SH

chmod +x "$tmp/bin/"*
export FAKE_PID FAKE_ACTION_LOG="$tmp/actions.log"
export LASTDBD_GUARD_NOTICE_CMD="$tmp/bin/situations"

MB=1048576
reset() {
  : >"$FAKE_ACTION_LOG"
  rm -f "$LOG" "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.state"
  rm -f "$EVENT_LOG"
  printf '{"pid":4242,"start_ts":1234,"last_heartbeat_ts":1234}\n' >"$LASTDBD_PRIMARY_HOME/current-session.json"
  printf '{"pid":4242,"start_ts":1234,"build_version":"0.0.0-test"}\n' >"$LASTDBD_PRIMARY_HOME/sessions.jsonl"
}
restarted() { grep -q 'launchctl kickstart' "$FAKE_ACTION_LOG" 2>/dev/null; }

# --- 1. invalid metric is rejected loudly rather than defaulting -------------
reset
if LASTDBD_GUARD_METRIC=bogus "$GUARD" >/dev/null 2>&1; then
  fail "invalid LASTDBD_GUARD_METRIC should exit non-zero"
fi

# --- 2. default policy uses footprint at 16 GiB and keeps steady state safe --
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
FAKE_PEAK_BYTES=$((12500 * MB)) \
FAKE_SWAP_MB=25000 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 below the default limit"

restarted && fail "default footprint policy must not restart at steady state"
grep -q 'metric=footprint' "$LOG" || fail "default metric should be footprint"
grep -q 'limit_mb=16384' "$LOG" || fail "default limit should be 16384 MiB"
grep -q 'footprint_mb=9000' "$LOG" || fail "log should carry the footprint gauge"
grep -q 'peak_mb=12500' "$LOG" || fail "log should carry the footprint peak"
grep -q 'rss_mb=1500' "$LOG" || fail "log should still carry rss"
grep -q 'swap_mb=' "$LOG" || fail "log should carry swap for diagnosis"
grep -q 'warn swap_used' "$LOG" && fail "swap use alone must not raise an alert"

# --- 3. default policy fires when footprint exceeds 16 GiB -------------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
FAKE_PEAK_BYTES=$((17100 * MB)) \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a restart"
restarted || fail "default footprint policy must restart above 16 GiB"
grep -q 'OVER_LIMIT.*metric=footprint.*enforced_mb=17000.*limit_mb=16384' "$LOG" \
  || fail "over-limit line should record the default footprint policy"
grep -q '"event":"restart_requested".*"old_pid":4242.*"new_pid":null' "$EVENT_LOG" \
  || fail "restart request should be durable before the signal"
grep -q '"event":"restart_observed".*"old_pid":4242.*"new_pid":4243' "$EVENT_LOG" \
  || fail "replacement pid should be durable after restart"
grep -q 'situations notice .*--actor agent:lastdb-memory-guard.*pid 4242 -> 4243' "$FAKE_ACTION_LOG" \
  || fail "a forced restart should post an attributed Situations notice"
notice_slug=$(sed -n 's/.*--slug \([^ ]*\).*/\1/p' "$FAKE_ACTION_LOG" | head -1)
printf '%s' "$notice_slug" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
  || fail "notice slug '$notice_slug' is not a valid Situations slug (invalid_slug rejects the write)"
grep -q 'WARN notice_failed' "$LOG" \
  && fail "the generated slug must satisfy the Situations slug rule"
grep -q 'notice posted slug=lastdb-memory-guard-restart-' "$LOG" \
  || fail "an accepted notice should record the slug it posted"

# --- 4. an explicit footprint limit override still applies -------------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((8700 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a restart"
restarted || fail "footprint enforcement must restart when footprint exceeds the limit"
grep -q 'OVER_LIMIT.*metric=footprint.*enforced_mb=8700' "$LOG" \
  || fail "over-limit line should name the footprint gauge and reading"

# --- 5. default footprint policy declines rather than falling back to rss -----
# Falling back would silently restore the blind spot the policy closed.
reset
FAKE_NODE_DOWN=1 \
FAKE_RSS_KB=$((1500 * 1024)) \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 when it declines to enforce"
restarted && fail "must not restart on an unavailable footprint reading"
grep -q 'footprint_unavailable' "$LOG" || fail "declining to enforce must be logged"

# --- 6. explicit rss compatibility mode exposes its blind spot ----------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((8700 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "rss compatibility mode should exit 0"
restarted && fail "rss mode must not restart when only footprint is over"
grep -q 'WARN blind_spot' "$LOG" || fail "rss blind spot must be logged"

# --- 7. explicit rss compatibility mode still fires on rss -------------------
reset
FAKE_RSS_KB=$((7000 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
FAKE_PEAK_BYTES=$((11110 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after an rss restart"
restarted || fail "rss enforcement must still fire when rss exceeds the limit"

# --- 8. node unreachable under explicit rss mode still guards on rss ----------
reset
FAKE_NODE_DOWN=1 \
FAKE_RSS_KB=$((7000 * 1024)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 with node unreachable"
restarted || fail "rss enforcement must not depend on the status socket"
grep -q 'footprint_mb=unavailable' "$LOG" || fail "unavailable footprint should be stated, not omitted"

# --- 9. identity mode is read-only and carries pid, start time, and build ----
reset
identity="$(FAKE_BOOT_START=5678 FAKE_BOOT_BUILD=0.23.3-test "$GUARD" --identity)" \
  || fail "identity mode should succeed for the primary"
[ "$identity" = 'pid=4242 process_start_ts=5678 build=0.23.3-test' ] \
  || fail "identity mode returned unexpected evidence: $identity"
restarted && fail "identity mode must never restart the primary"

if FAKE_NODE_DOWN=1 "$GUARD" --identity >/dev/null 2>&1; then
  fail "missing boot identity must fail instead of falling back to status or files"
fi

# --- 10. a rejected notice records WHY, so a wrong fix cannot look green -----
# The restart itself must still complete and stay durable in the event log.
reset
cat >"$tmp/bin/situations-reject" <<'SH'
#!/usr/bin/env bash
echo 'Invalid slug "boom".' >&2
exit 2
SH
chmod +x "$tmp/bin/situations-reject"
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
FAKE_PEAK_BYTES=$((17100 * MB)) \
LASTDBD_GUARD_NOTICE_CMD="$tmp/bin/situations-reject" \
  "$GUARD" >/dev/null 2>&1 || fail "a rejected notice must not fail the guard"
restarted || fail "a rejected notice must not block the restart"
grep -q 'WARN notice_failed .*reason=.*Invalid slug' "$LOG" \
  || fail "a rejected notice should record the reason the CLI gave"
grep -q '"event":"restart_observed"' "$EVENT_LOG" \
  || fail "restart evidence must stay durable when the notice is rejected"

printf 'PASS: last-stack-lastdb-memory-guard\n'
