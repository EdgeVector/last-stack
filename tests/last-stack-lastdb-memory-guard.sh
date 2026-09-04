#!/usr/bin/env bash
# last-stack-lastdb-memory-guard fixtures.
#
# The guard is a process-killer aimed at the primary brain, so the properties
# under test are mostly about when it does NOT fire:
#   - default enforcement is footprint at the ratified 16 GiB limit
#   - steady-state footprint below that limit causes no action
#   - footprint comes from proc_pid_rusage, not /api/status, so it stays
#     available even when the node's own socket is unreachable
#   - a forced restart sheds first (POST /api/admin/shed) and only proceeds to
#     vmmap capture + SIGTERM when the footprint does not fall (fold #1908 port)
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
export LASTDBD_GUARD_SHED_WAIT_SEC=1
export LASTDBD_GUARD_TERM_WAIT_SEC=1
LOG="$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.log"
EVENT_LOG="$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard-events.jsonl"

FAKE_PID=4242

# Fake ps covering every form the guard uses. RSS is fed via FAKE_RSS_KB.
cat >"$tmp/bin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "-Ao pid=,comm=")
    # FAKE_NO_PRIMARY=1 means the daemon is gone. A bootstrap in the action log
    # brings it back, which is how the revival tests observe recovery.
    if [ "${FAKE_NO_PRIMARY:-0}" = "1" ] \
       && ! grep -q 'launchctl bootstrap' "$FAKE_ACTION_LOG" 2>/dev/null; then
      exit 0
    fi
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

# Fake python3: shims phys_footprint_mb_of's proc_pid_rusage read. The guard
# passes the pid as argv and a throwaway ctypes script on stdin; both are
# ignored — the byte count comes straight from the fixture's env vars, and
# FAKE_SHED_MARKER lets a test observe footprint falling after a shed.
cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_FOOTPRINT_FAIL:-0}" = "1" ]; then
  exit 1
fi
if [ -f "${FAKE_SHED_MARKER:-/nonexistent-shed-marker}" ]; then
  printf '%s\n' "${FAKE_FOOTPRINT_BYTES_AFTER_SHED:-${FAKE_FOOTPRINT_BYTES:-0}}"
else
  printf '%s\n' "${FAKE_FOOTPRINT_BYTES:-0}"
fi
SH

# Fake vmmap: records the capture attempt instead of scanning a pid that does
# not really exist.
cat >"$tmp/bin/vmmap" <<'SH'
#!/usr/bin/env bash
printf 'vmmap %s\n' "$*" >>"$FAKE_ACTION_LOG"
echo "fake vmmap summary"
SH

# Fake curl: serves status and the bounded boot-identity route unless the node
# is unavailable. Honor -w '%{http_code}' so identity can distinguish 404.
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
# A connection failure. Real curl STILL emits the -w write-out in this case,
# as the literal 000, and a shim that exits silently hides every caller that
# mistakes a non-empty code for a live socket. One did.
down() {
  for a in "$@"; do
    case "$a" in *%{http_code}*) printf '\n000'; exit 7 ;; esac
  done
  exit 7
}
if [ "${FAKE_NODE_DOWN:-0}" = "1" ]; then down "$@"; fi
# FAKE_SOCKET_UP=1 keeps the socket answering while ps reports no daemon —
# the "our selector missed it" case the revival path must fail closed on.
if [ "${FAKE_NO_PRIMARY:-0}" = "1" ] && [ "${FAKE_SOCKET_UP:-0}" != "1" ] \
   && ! grep -q 'launchctl bootstrap' "$FAKE_ACTION_LOG" 2>/dev/null; then down "$@"; fi
want_code=0
for arg in "$@"; do
  case "$arg" in
    *%{http_code}*) want_code=1 ;;
  esac
done
emit() {
  printf '%s' "$1"
  if [ "$want_code" = 1 ]; then
    printf '\n%s' "$2"
  fi
}
case "$*" in
  *"/api/admin/shed"*)
    code="${FAKE_SHED_HTTP:-404}"
    if [ "$code" = "200" ]; then
      touch "$FAKE_SHED_MARKER"
    fi
    emit "" "$code"
    exit 0
    ;;
esac
case "$*" in
  *"/api/system/boot-identity"*)
    if [ "${FAKE_BOOT_HTTP:-200}" = "404" ]; then
      emit "Not Found" "404"
      exit 0
    fi
    boot_pid="${FAKE_BOOT_PID:-${FAKE_PID:-4242}}"
    if [ -z "${FAKE_BOOT_PID:-}" ] && grep -q 'launchctl kickstart' "$FAKE_ACTION_LOG" 2>/dev/null; then
      boot_pid=$((boot_pid + 1))
    fi
    emit "$(printf '{"pid":%s,"process_start_ts":%s,"build":"%s","restart_cause":"%s"}' \
      "$boot_pid" "${FAKE_BOOT_START:-1234}" \
      "${FAKE_BOOT_BUILD:-0.0.0-test}" "${FAKE_BOOT_CAUSE:-initial}")" "200"
    exit 0
    ;;
esac
if [ "${FAKE_STATUS_EMPTY:-0}" = "1" ]; then
  emit "" "200"
  exit 0
fi
emit "$(printf '{"status":{"rss_bytes":%s,"phys_footprint_bytes":%s,"phys_footprint_peak_bytes":%s,"process_start_ts":%s,"build":{"version":"%s"}}}' \
  "${FAKE_RSS_BYTES:-0}" "${FAKE_FOOTPRINT_BYTES:-0}" "${FAKE_PEAK_BYTES:-0}" \
  "${FAKE_START_TS:-1234}" "${FAKE_BUILD:-0.0.0-test}")" "200"
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
  list)
    # An unloaded agent is ABSENT from the list, not listed as stopped. That
    # distinction is the whole trigger, so the shim has to reproduce it.
    if [ "${FAKE_AGENT_LOADED:-1}" = "1" ] \
       || grep -q 'launchctl bootstrap' "$FAKE_ACTION_LOG" 2>/dev/null; then
      printf '%s\t0\tcom.example.lastdbd-primary\n' "${FAKE_PID:-4242}"
    fi
    ;;
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
case "${1:-}" in
  preflight) exit "${FAKE_PREFLIGHT_RC:-0}" ;;
esac
case " $* " in
  *" --actor agent:lastdb-memory-guard "*) ;;
  *) echo "unexpected actor" >&2; exit 2 ;;
esac
SH

chmod +x "$tmp/bin/"*
export FAKE_PID FAKE_ACTION_LOG="$tmp/actions.log"
export FAKE_SHED_MARKER="$tmp/shed-posted"
export LASTDBD_GUARD_NOTICE_CMD="$tmp/bin/situations"

# A LaunchAgent directory holding the primary's plist, a decoy for a DIFFERENT
# home, and a .bak- copy — the three shapes that actually sit in
# ~/Library/LaunchAgents on the machine this guard runs on.
export LASTDBD_GUARD_PLIST_DIR="$tmp/agents"
export LASTDBD_GUARD_REVIVE_WAIT_SEC=3
mkdir -p "$LASTDBD_GUARD_PLIST_DIR"
write_agents() {
  rm -f "$LASTDBD_GUARD_PLIST_DIR"/*
  printf '<plist><string>%s</string></plist>\n' "$LASTDBD_PRIMARY_HOME" \
    >"$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary.plist"
  printf '<plist><string>%s</string></plist>\n' "/somewhere/else/.lastdb" \
    >"$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary-other.plist"
  printf '<plist><string>%s</string></plist>\n' "$LASTDBD_PRIMARY_HOME" \
    >"$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary.plist.bak-20260101"
}

MB=1048576
reset() {
  : >"$FAKE_ACTION_LOG"
  rm -f "$LOG" "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-memory-guard.state"
  rm -f "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-absent.state"
  rm -f "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-revive.hold"
  rm -f "$EVENT_LOG"
  rm -f "$FAKE_SHED_MARKER"
  write_agents
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
FAKE_SWAP_MB=25000 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 below the default limit"

restarted && fail "default footprint policy must not restart at steady state"
grep -q 'metric=footprint' "$LOG" || fail "default metric should be footprint"
grep -q 'limit_mb=16384' "$LOG" || fail "default limit should be 16384 MiB"
grep -q 'footprint_mb=9000' "$LOG" || fail "log should carry the footprint gauge"
grep -q 'footprint_source=rusage' "$LOG" || fail "footprint should come from rusage by default"
grep -q 'rss_mb=1500' "$LOG" || fail "log should still carry rss"
grep -q 'swap_mb=' "$LOG" || fail "log should carry swap for diagnosis"
grep -q 'warn swap_used' "$LOG" && fail "swap use alone must not raise an alert"

# --- 3. default policy fires when footprint exceeds 16 GiB; an unsupported
# (404) shed route never fails closed and the restart still proceeds ---------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a restart"
restarted || fail "default footprint policy must restart above 16 GiB"
grep -q 'OVER_LIMIT.*metric=footprint.*enforced_mb=17000.*limit_mb=16384' "$LOG" \
  || fail "over-limit line should record the default footprint policy"
grep -q 'shed_unsupported' "$LOG" || fail "a 404 shed route should be logged and not block the restart"
grep -q 'vmmap_capture\|vmmap_skip' "$LOG" || fail "a forced restart should attempt a vmmap capture"
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
LASTDBD_RSS_LIMIT_MB=6144 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a restart"
restarted || fail "footprint enforcement must restart when footprint exceeds the limit"
grep -q 'OVER_LIMIT.*metric=footprint.*enforced_mb=8700' "$LOG" \
  || fail "over-limit line should name the footprint gauge and reading"

# --- 5. a failed rusage read falls back to rss and records the source -------
# rusage is a local syscall, not a network call, so this only happens off
# macOS or when the pid has just raced away — it must not block a whole cycle.
reset
FAKE_FOOTPRINT_FAIL=1 \
FAKE_RSS_KB=$((1500 * 1024)) \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 when the rusage read fails"
restarted && fail "an rss-equivalent footprint below the limit must not restart"
grep -q 'footprint_source=rss_fallback' "$LOG" || fail "a rusage failure should record the fallback source"
grep -q 'footprint_mb=1500' "$LOG" || fail "the fallback footprint should equal rss"

# --- 6. explicit rss compatibility mode exposes its blind spot ----------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((8700 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "rss compatibility mode should exit 0"
restarted && fail "rss mode must not restart when only footprint is over"
grep -q 'WARN blind_spot' "$LOG" || fail "rss blind spot must be logged"

# --- 7. explicit rss compatibility mode still fires on rss -------------------
reset
FAKE_RSS_KB=$((7000 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after an rss restart"
restarted || fail "rss enforcement must still fire when rss exceeds the limit"

# --- 8. footprint via rusage does not depend on the status socket: a node
# that cannot answer HTTP still reports a real footprint and rss still fires -
reset
FAKE_NODE_DOWN=1 \
FAKE_RSS_KB=$((7000 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
LASTDBD_RSS_LIMIT_MB=6144 \
LASTDBD_GUARD_METRIC=rss \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 with node unreachable"
restarted || fail "rss enforcement must not depend on the status socket"
grep -q 'footprint_mb=9000' "$LOG" || fail "rusage footprint must not depend on socket reachability"
grep -q 'footprint_source=rusage' "$LOG" || fail "footprint source should still be rusage when the socket is down"

# --- 9. identity mode is read-only and carries pid, start time, and build ----
reset
identity="$(FAKE_BOOT_START=5678 FAKE_BOOT_BUILD=0.23.3-test "$GUARD" --identity)" \
  || fail "identity mode should succeed for the primary"
[ "$identity" = 'pid=4242 process_start_ts=5678 build=0.23.3-test identity_source=boot_identity' ] \
  || fail "identity mode returned unexpected evidence: $identity"
restarted && fail "identity mode must never restart the primary"

if FAKE_NODE_DOWN=1 "$GUARD" --identity >/dev/null 2>&1; then
  fail "a down socket must fail instead of falling back to status or files"
fi

# HTTP 404 on boot-identity falls back to a bounded /api/status read.
reset
identity="$(FAKE_BOOT_HTTP=404 FAKE_BUILD=0.23.3-status FAKE_START_TS=9999 "$GUARD" --identity)" \
  || fail "HTTP 404 on boot-identity should fall back to status"
[ "$identity" = 'pid=4242 process_start_ts=9999 build=0.23.3-status identity_source=status_fallback' ] \
  || fail "404 fallback returned unexpected evidence: $identity"
restarted && fail "404 identity fallback must never restart the primary"

# HTTP 404 with empty status is still a line-stop.
reset
if FAKE_BOOT_HTTP=404 FAKE_STATUS_EMPTY=1 "$GUARD" --identity >/dev/null 2>&1; then
  fail "empty status after a boot-identity 404 must fail"
fi
restarted && fail "empty-status identity failure must never restart the primary"

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
LASTDBD_GUARD_NOTICE_CMD="$tmp/bin/situations-reject" \
  "$GUARD" >/dev/null 2>&1 || fail "a rejected notice must not fail the guard"
restarted || fail "a rejected notice must not block the restart"
grep -q 'WARN notice_failed .*reason=.*Invalid slug' "$LOG" \
  || fail "a rejected notice should record the reason the CLI gave"
grep -q '"event":"restart_observed"' "$EVENT_LOG" \
  || fail "restart evidence must stay durable when the notice is rejected"

revived() { grep -q 'launchctl bootstrap' "$FAKE_ACTION_LOG" 2>/dev/null; }

# The revival cases below all describe the same outage: the primary daemon is
# gone AND its LaunchAgent is not loaded, so KeepAlive cannot bring it back.
# Before this guard owned that case it logged `ok no_primary_lastdbd` and
# exited, which is what let three outages run 4, 14 and 38 minutes.

# --- 11. absent + unloaded revives, but only after the state persists --------
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 "$GUARD" >/dev/null 2>&1 \
  || fail "guard should exit 0 on the first absent cycle"
revived && fail "a single absent cycle must not revive (that is an upgrade window)"
grep -q 'absent_cycles=1/2' "$LOG" || fail "the first cycle should record the wait"

FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 "$GUARD" >/dev/null 2>&1 \
  || fail "guard should exit 0 on the revive cycle"
revived || fail "a persistent absent+unloaded state must revive the agent"
grep -q 'launchctl enable ' "$FAKE_ACTION_LOG" \
  || fail "enable must precede bootstrap; launchctl disable outlives a rename"
grep -q 'REVIVE primary lastdbd agent=com.example.lastdbd-primary' "$LOG" \
  || fail "the revive should name the agent it bootstrapped"
grep -q 'revive verified agent=com.example.lastdbd-primary new_pid=' "$LOG" \
  || fail "revival is verified by the socket answering, and must be logged"
grep -q '"event":"revive_requested"' "$EVENT_LOG" \
  || fail "the revive request should be durable before the bootstrap"
grep -q '"event":"revive_observed"' "$EVENT_LOG" \
  || fail "the observed recovery should be durable"
grep -q 'situations notice .*--slug lastdb-memory-guard-revive-' "$FAKE_ACTION_LOG" \
  || fail "a revive should post a notice so socket errors read as that outage"
revive_slug=$(sed -n 's/.*--slug \(lastdb-memory-guard-revive-[^ ]*\).*/\1/p' "$FAKE_ACTION_LOG" | head -1)
printf '%s' "$revive_slug" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
  || fail "revive notice slug '$revive_slug' is not a valid Situations slug"
grep -q 'WARN notice_failed' "$LOG" && fail "the revive notice slug must be accepted"

# --- 12. a loaded agent is KeepAlive's job — never race it -------------------
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=1 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=1 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "must not bootstrap an agent launchd already owns"
grep -q 'loaded=yes' "$LOG" || fail "the loaded case should say so"

# --- 13. a socket that answers means someone owns this home — fail closed ----
# The process selector deliberately fails closed, so "no pid" can mean "missed
# it". Starting a second daemon on the same home would be worse than the outage.
reset
FAKE_NO_PRIMARY=1 FAKE_SOCKET_UP=1 FAKE_AGENT_LOADED=0 \
  LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "must not revive while the primary socket still answers"
grep -q 'answers — not reviving' "$LOG" || fail "the live-socket refusal should be logged"

# --- 14. a maintenance hold suppresses revival ------------------------------
reset
touch "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-revive.hold"
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 \
  "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "a hold file must suppress revival"
grep -q 'revive=held' "$LOG" || fail "the hold should be logged with its path"

# --- 15. a deliberately parked agent is not an outage -----------------------
reset
mv "$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary.plist" \
   "$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary.plist.paused-20260101"
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 \
  PRIMARY_AGENT_LABEL= LASTDBD_PRIMARY_AGENT_LABEL=com.example.lastdbd-primary \
  "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "a .paused-* marker means parked on purpose"
grep -q 'parked=yes' "$LOG" || fail "the parked case should be logged"

# --- 16. ambiguous or foreign plists are refused, not guessed ---------------
reset
printf '<plist><string>%s</string></plist>\n' "$LASTDBD_PRIMARY_HOME" \
  >"$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary-second.plist"
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 \
  "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "two candidate plists for one home must refuse, not guess"
grep -q 'reason=no_unique_primary_plist' "$LOG" || fail "the refusal should say why"

reset
rm -f "$LASTDBD_GUARD_PLIST_DIR/com.example.lastdbd-primary.plist"
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 \
  "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "a plist naming a different home must not be started"
grep -q 'reason=no_unique_primary_plist' "$LOG" \
  || fail "only the decoy remains, so no unique candidate exists"

# --- 17. a blocking Situation stops the revive ------------------------------
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 \
  FAKE_PREFLIGHT_RC=3 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "preflight exit 3 requires human clearance"
grep -q 'revive=blocked' "$LOG" || fail "the block should be logged"

# --- 18. revival can be switched off entirely -------------------------------
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 LASTDBD_GUARD_REVIVE=0 \
  LASTDBD_GUARD_REVIVE_MIN_ABSENT_CYCLES=1 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
revived && fail "LASTDBD_GUARD_REVIVE=0 must disable revival"
grep -q 'revive=disabled' "$LOG" || fail "the disabled state should be logged"

# --- 19. a healthy cycle clears the absent counter --------------------------
# Otherwise a flapping primary would accumulate cycles across unrelated outages
# and revive on its first absent cycle much later.
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
[ -f "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-absent.state" ] \
  || fail "an absent cycle should be recorded"
FAKE_RSS_KB=$((1500 * 1024)) FAKE_FOOTPRINT_BYTES=$((9000 * MB)) \
  "$GUARD" >/dev/null 2>&1 || fail "exit 0 expected"
[ -f "$LASTDBD_PRIMARY_HOME/monitoring/lastdbd-absent.state" ] \
  && fail "a healthy cycle must clear the absent counter"

# --- 20. identity mode stays read-only on the revival path ------------------
reset
FAKE_NO_PRIMARY=1 FAKE_AGENT_LOADED=0 "$GUARD" --identity >/dev/null 2>&1 \
  && fail "identity should fail when there is no primary"
revived && fail "identity mode must never bootstrap anything"

# --- 21. a shed that recovers the footprint skips SIGTERM entirely ----------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
FAKE_SHED_HTTP=200 \
FAKE_FOOTPRINT_BYTES_AFTER_SHED=$((9000 * MB)) \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 when shed recovers the footprint"
restarted && fail "a shed that recovers footprint must not kill the primary"
grep -q 'shed_ok' "$LOG" || fail "a 200 from /api/admin/shed should be logged"
grep -q 'shed_recovered pid=4242 footprint_mb=9000' "$LOG" \
  || fail "recovery should be logged with the post-shed footprint"

# --- 22. a shed that never recovers falls through to vmmap + SIGTERM -------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
FAKE_SHED_HTTP=200 \
  "$GUARD" >/dev/null 2>&1 || fail "guard should exit 0 after a shed-timeout restart"
restarted || fail "a shed that does not recover footprint must still restart"
grep -q 'shed_ok' "$LOG" || fail "the shed attempt should be logged"
grep -q 'shed_timeout' "$LOG" || fail "a shed that never recovers should log the timeout"
grep -q 'vmmap_capture' "$LOG" || fail "a forced restart after a shed timeout should capture vmmap"

# --- 23. dry run logs intent and takes no action whatsoever ------------------
reset
FAKE_RSS_KB=$((1500 * 1024)) \
FAKE_FOOTPRINT_BYTES=$((17000 * MB)) \
LASTDBD_GUARD_DRY_RUN=1 \
  "$GUARD" >/dev/null 2>&1 || fail "dry run should exit 0"
restarted && fail "dry run must never kill or kickstart the primary"
grep -q 'dry_run skip shed/kill/kickstart' "$LOG" || fail "dry run should log its intent"
[ -s "$FAKE_ACTION_LOG" ] && fail "dry run must not touch kill/launchctl/situations/vmmap"

# --- 24. shipped rusage python: oversized buffer, real pid, exit 0 ----------
# The PATH python3 above is a fixture for the rest of this file. This check
# drives the shipped helper with the real interpreter and must not use that
# shim.

rusage_py="$tmp/shipped-rusage.py"
awk '
  /phys_footprint_mb_of\(\)/ { in_fn=1 }
  in_fn && /<<'\''PY'\''/ { grab=1; next }
  grab && $0 == "PY" { exit }
  grab { print }
' "$GUARD" >"$rusage_py"
[ -s "$rusage_py" ] || fail "could not extract shipped rusage python from $GUARD"

grep -q 'class rusage_info_v4' "$GUARD" && fail "shipped guard still declares ctypes rusage_info_v4"
grep -q 'BUF_SIZE = 1024' "$rusage_py" || fail "shipped rusage python must use a 1024-byte buffer"
grep -q 'PHYS_FOOTPRINT_OFFSET = 72' "$rusage_py" || fail "shipped rusage python must unpack phys_footprint at offset 72"
grep -q 'c_uint8 \* BUF_SIZE' "$rusage_py" || fail "shipped rusage python must allocate BUF_SIZE bytes, not a 248-byte Structure"

python3_real="${LAST_STACK_TEST_PYTHON3:-/usr/bin/python3}"
if [ ! -x "$python3_real" ]; then
  python3_real="$(command -v python3 || true)"
fi
[ -n "$python3_real" ] || fail "no python3 for the real rusage check"

if [ "$(uname -s)" = "Darwin" ]; then
  short_py="$tmp/short-rusage-v4.py"
  cat >"$short_py" <<'SHORT'
import ctypes, ctypes.util, sys
pid = int(sys.argv[1])
libc = ctypes.CDLL(ctypes.util.find_library("c"))
class rusage_info_v4(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
    ]
info = rusage_info_v4()
libc.proc_pid_rusage(pid, 4, ctypes.byref(info))
print(info.ri_phys_footprint)
SHORT
  short_ec=0
  "$python3_real" "$short_py" "$$" >/dev/null 2>&1 || short_ec=$?
  [ "$short_ec" -ne 0 ] || fail "248-byte rusage_info_v4 should still overflow (got exit 0)"

  out1="$tmp/rusage-live-1.txt"
  set +e
  "$python3_real" - "$$" <"$rusage_py" >"$out1"
  ec1=$?
  set -e
  [ "$ec1" -eq 0 ] || fail "shipped rusage python exit $ec1 (want 0, not 139) pid=$$"
  bytes1=$(tr -d ' \n' <"$out1")
  case "$bytes1" in
    ''|*[!0-9]*) fail "shipped rusage python stdout not a positive integer: '$bytes1'" ;;
  esac
  [ "$bytes1" -gt 0 ] || fail "shipped rusage python printed non-positive: $bytes1"

  out2="$tmp/rusage-live-2.txt"
  set +e
  "$python3_real" - "$$" <"$rusage_py" >"$out2"
  ec2=$?
  set -e
  [ "$ec2" -eq 0 ] || fail "second shipped rusage python exit $ec2 (want 0, not 139)"
  bytes2=$(tr -d ' \n' <"$out2")
  case "$bytes2" in
    ''|*[!0-9]*) fail "second shipped rusage python stdout not a positive integer: '$bytes2'" ;;
  esac
  [ "$bytes2" -gt 0 ] || fail "second shipped rusage python printed non-positive: $bytes2"
fi

printf 'PASS: last-stack-lastdb-memory-guard\n'
