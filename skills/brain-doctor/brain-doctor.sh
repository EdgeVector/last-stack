#!/bin/bash
# brain-doctor.sh — READ-ONLY triage of the folddb brain (Tom's primary
# fbrain/fkanban daily-driver node) and the orphan procs that masquerade as it.
#
# The brain (the desktop `fold-app` process) is reached over a Unix socket — it
# serves the same node over BOTH ~/.lastdb/data/folddb.sock and the legacy
# ~/.folddb/data/folddb.sock (both return HTTP 200). The legacy local TCP endpoint
# is intentionally SHUT DOWN, so a TCP probe (or an `lsof -i` on the old port) finds
# nothing even when the brain is perfectly healthy. NEVER treat a missing TCP
# listener as a node outage; the socket is the source of truth. Note: on the
# ~/.folddb path `lsof -t` can return EMPTY while the socket is healthy, so this
# script defaults to ~/.lastdb (where lsof attributes the listener PID) and
# identifies the brain by process name (fold-app) too, not lsof alone.
#
# Codifies the hand-run recipe that recurs across every "is fkanban down / is the
# brain wedged / why is my computer slow / couldn't take over" incident. Pulls
# together: sled-IO deadlock triage (full vs partial wedge), dup-supervisor
# detection, and the orphan-folddb_server sweep classifier.
#
# SAFETY: this script NEVER kills, restarts, writes, or stashes anything. It only
# reads state and PRINTS the recommended recovery command for a human to run.
# That honors the standing rule: never kill the brain / surface-don't-act unattended.
#
# Usage:  brain-doctor.sh [SOCKET]   (SOCKET defaults to ~/.lastdb/data/folddb.sock,
#         falling back to ~/.folddb/data/folddb.sock; FOLDDB_SOCKET env also overrides)
# Exit:   0 = healthy   1 = degraded/partial   2 = wedged/down   3 = not running

set -u
LASTDB_HOME="${LASTDB_HOME:-$HOME/.lastdb}"
FOLDDB_HOME="${FOLDDB_HOME:-$HOME/.folddb}"
# The brain (the desktop `fold-app` process) serves the SAME node over BOTH
# ~/.lastdb/data/folddb.sock and ~/.folddb/data/folddb.sock (both return HTTP 200).
# Prefer ~/.lastdb: `lsof -t` reliably attributes the listener PID there, whereas on
# ~/.folddb `lsof -t` can return EMPTY even though the socket is perfectly healthy
# (curl still gets 200). Arg / FOLDDB_SOCKET override wins; else prefer lastdb, fall
# back to the legacy folddb path.
if [ -n "${1:-}" ]; then SOCKET="$1"
elif [ -n "${FOLDDB_SOCKET:-}" ]; then SOCKET="$FOLDDB_SOCKET"
elif [ -S "$LASTDB_HOME/data/folddb.sock" ]; then SOCKET="$LASTDB_HOME/data/folddb.sock"
else SOCKET="$FOLDDB_HOME/data/folddb.sock"; fi
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-8}"

# --- tiny output helpers (bash 3.2 safe, no associative arrays) ---------------
bold(){ printf '\033[1m%s\033[0m\n' "$1"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$1"; }
info(){ printf '    %s\n' "$1"; }

STATUS=0   # worst status seen
bump(){ [ "$1" -gt "$STATUS" ] && STATUS="$1"; return 0; }

bold "════════════════════════════════════════════════════════════"
bold " folddb brain-doctor  —  socket $SOCKET  —  $(date '+%Y-%m-%d %H:%M:%S %Z')"
bold "════════════════════════════════════════════════════════════"

# ── 1. Socket + brain process ─────────────────────────────────────────────────
bold ""
bold "1. Brain socket + brain process (fold-app / lastdb_server)"
# The brain owns the Unix socket. Find the brain process that holds it. The live
# brain is the desktop `fold-app` (renamed from `folddb_server`/`lastdb_server`);
# match all three so identification survives the FoldDB→LastDB rename.
BRAIN_PID=""
if [ -S "$SOCKET" ]; then
  ok "socket present: $SOCKET"
  # who has the socket open (the server, plus any live clients)
  SOCK_PIDS="$(lsof -t "$SOCKET" 2>/dev/null)"
  for pid in $SOCK_PIDS; do
    CMD="$(ps -o command= -p "$pid" 2>/dev/null)"
    case "$CMD" in
      *fold-app*|*lastdb_server*|*folddb_server*) BRAIN_PID="$pid"; break ;;
    esac
  done
  # fall back to the brain process if lsof is restricted (sandbox) OR returns empty
  # (on ~/.folddb `lsof -t` can be empty while the socket is healthy — see header).
  if [ -z "$BRAIN_PID" ]; then
    for pid in $(pgrep -f 'MacOS/fold-app|lastdb_server|folddb_server' 2>/dev/null); do
      CMD="$(ps -o command= -p "$pid" 2>/dev/null)"
      case "$CMD" in *fold-app*|*lastdb_server*|*folddb_server*) BRAIN_PID="$pid"; break ;; esac
    done
  fi
else
  bad "no socket at $SOCKET — the brain is DOWN (or not yet up)."
  info "If launchd should be running it:  launchctl list | grep folddb"
  info "Recovery (graceful respawn):  launchctl kickstart -k gui/\$(id -u)/com.folddb.daemon"
  bump 3
fi

if [ -n "$BRAIN_PID" ]; then
  PS_LINE="$(ps -o pid=,ppid=,%cpu=,rss=,etime=,comm= -p "$BRAIN_PID" 2>/dev/null)"
  ok "PID $BRAIN_PID is the fold-app brain serving the socket"
  if [ -n "$PS_LINE" ]; then
    CPU="$(echo "$PS_LINE" | awk '{print $3}')"
    RSSKB="$(echo "$PS_LINE" | awk '{print $4}')"
    ETIME="$(echo "$PS_LINE" | awk '{print $5}')"
    COMM="$(echo "$PS_LINE" | awk '{print $6}')"
    PPID_V="$(echo "$PS_LINE" | awk '{print $2}')"
    info "cmd=$COMM  ppid=$PPID_V  cpu=${CPU}%  rss=$(( RSSKB / 1024 ))MB  uptime=$ETIME"
    [ "$PPID_V" = "1" ] && info "ppid=1 → launchd-supervised (expected for the durable brain)."
  fi
elif [ -S "$SOCKET" ]; then
  warn "socket exists but no brain process (fold-app / lastdb_server) resolved (ps/lsof may be sandbox-restricted)."
  info "If a board read works (fkanban doctor / fbrain get), the brain is alive — trust the socket op."
fi

# ── 2. Live clients (the do-not-kill signal) ─────────────────────────────────
bold ""
bold "2. Processes holding the socket (live-brain protection)"
if [ -S "$SOCKET" ]; then
  CLIENTS="$(lsof "$SOCKET" 2>/dev/null | grep -v '^COMMAND' | awk -v b="$BRAIN_PID" '$2 != b')"
  CLN="$(printf '%s\n' "$CLIENTS" | grep -c . )"
  if [ "$CLN" -gt 0 ]; then
    warn "$CLN process(es) other than the server hold the socket — this is a LIVE brain. Do NOT kill blindly."
    printf '%s\n' "$CLIENTS" | awk '{print "    • "$1" (pid "$2")"}' | sort -u | head -8
  else
    info "No other socket holders right now (still may be the real brain — check uptime/cmd above)."
  fi
fi

# ── 3. Health / hang probe (full vs partial wedge) ───────────────────────────
bold ""
bold "3. Responsiveness probe over the socket (timeout ${HEALTH_TIMEOUT}s)"
if [ -S "$SOCKET" ]; then
  T0=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || echo 0)
  BODY="$(curl -s -m "$HEALTH_TIMEOUT" --unix-socket "$SOCKET" -o /dev/null -w '%{http_code}' "http://localhost/" 2>/dev/null)"
  CURL_RC=$?
  T1=$(perl -MTime::HiRes=time -e 'print time' 2>/dev/null || echo 0)
  LAT="?"
  if [ "$T0" != "0" ] && [ "$T1" != "0" ]; then LAT="$(perl -e "printf '%.2f', $T1-$T0" 2>/dev/null)"; fi
  if [ "$CURL_RC" -eq 28 ]; then
    bad "GET / over socket TIMED OUT after ${HEALTH_TIMEOUT}s — FULL WEDGE (SIGTERM-deaf sled deadlock)."
    info "Confirm with:  sample $BRAIN_PID 5   (expect parked sled apply_batch / make_stable threads)"
    info "Recovery: a plain restart leaves the wedged PID on the socket — you MUST kill -9:"
    info "    kill -9 $BRAIN_PID    # launchd KeepAlive respawns a fresh, healthy PID"
    info "    then re-check the PID actually changed."
    bump 2
  elif [ "$CURL_RC" -ne 0 ] && [ -z "$BODY" ]; then
    # rc!=0 with no body and not a timeout: socket present but no HTTP reply.
    # Could be a non-HTTP server or a half-open socket — fall back to a real op.
    warn "no HTTP reply over the socket (curl rc=$CURL_RC). Confirm liveness with a socket-backed op:"
    info "    cd ~/code/edgevector/fkanban && bun run src/cli.ts doctor"
    info "    (a successful board read / fbrain get means the brain is alive — do NOT restart)"
    bump 1
  elif [ "$BODY" = "000" ]; then
    # curl can exit rc=0 with %{http_code}=000 when a connection is accepted and
    # closed without a valid HTTP reply. That is not a responsive HTTP read path.
    warn "GET / over socket → HTTP 000 (connection accepted, no valid HTTP reply) — NOT alive."
    info "Confirm with a socket-backed op:  cd ~/code/edgevector/fkanban && bun run src/cli.ts doctor"
    info "If that also fails: the node is up but wedged/mid-restart, not down. Re-check shortly —"
    info "~/.folddb/watchdog.sh self-heals a confirmed wedge (3 consecutive failures) automatically."
    bump 2
  else
    ok "GET / over socket → HTTP $BODY in ${LAT}s (read path is alive)."
    SLOW=$(perl -e "print( ($LAT eq '?')?0:(($LAT>5)?1:0) )" 2>/dev/null || echo 0)
    if [ "$SLOW" = "1" ]; then
      warn "Read latency >5s — could be the partial WRITE-path / embedding stall (reads ok, big writes hang >300s)."
      info "If fbrain/fkanban WRITES hang but reads are instant, that's the partial wedge."
      info "Graceful fix works for the partial wedge (no kill -9 needed):"
      info "    launchctl kickstart -k gui/\$(id -u)/com.folddb.daemon"
      bump 1
    fi
  fi
fi

# ── 4. Supervisors (dup-supervisor drift) ────────────────────────────────────
bold ""
bold "4. launchd / brew supervisors for folddb"
LC="$(launchctl list 2>/dev/null | grep -i folddb)"
# count only daemon-style labels (exclude the GUI .app entry)
DAEMON_SUP="$(printf '%s\n' "$LC" | grep -iv 'folddb\.app' | grep -i folddb)"
NDAEMON="$(printf '%s\n' "$DAEMON_SUP" | grep -c .)"
if [ "$NDAEMON" -eq 0 ]; then
  warn "No folddb daemon LaunchAgent found (brain may be hand-started, not durable)."
else
  printf '%s\n' "$DAEMON_SUP" | awk '{print "    • label="$3"  pid="$1"  laststatus="$2}'
  if [ "$NDAEMON" -gt 1 ]; then
    bad "MORE THAN ONE folddb daemon supervisor → drift (the 'couldn't take over' class)."
    info "Expected: exactly one, label com.folddb.daemon. Legacy com.tomtang.folddb should be gone."
    info "Remove the loser:  launchctl bootout gui/\$(id -u)/<legacy-label>"
    bump 1
  else
    ok "Exactly one folddb daemon supervisor."
  fi
fi
BREW_F="$(brew services list 2>/dev/null | grep -i '^folddb' )"
if [ -n "$BREW_F" ]; then
  BREW_STATE="$(echo "$BREW_F" | awk '{print $2}')"
  if [ "$BREW_STATE" != "none" ] && [ -n "$BREW_STATE" ]; then
    bad "brew services ALSO supervises folddb ($BREW_STATE) → duplicate supervisor."
    info "Remove it:  brew services stop folddb"
    bump 1
  else
    ok "brew services not supervising folddb (state=$BREW_STATE)."
  fi
fi

# ── 5. Stale port breadcrumb (vestigial since TCP shutdown) ──────────────────
bold ""
bold "5. ~/.folddb/port breadcrumb"
PORTFILE="$FOLDDB_HOME/port"
if [ -f "$PORTFILE" ]; then
  WROTE="$(tr -d '[:space:]' < "$PORTFILE" 2>/dev/null)"
  info "Breadcrumb file present (value '$WROTE'). VESTIGIAL — the TCP endpoint is shut down;"
  info "the brain is reached over $SOCKET now. Harmless; takeover uses the lock file (fold#812)."
else
  info "No $PORTFILE (fine — the socket, not a TCP port, is the rendezvous now)."
fi

# ── 6. Orphan / impostor folddb procs (sweep candidates) ─────────────────────
bold ""
bold "6. Orphan lastdb_server/folddb_server test-node procs (NOT the primary-socket brain)"
FOUND_ORPHAN=0
# Orphaned TEST-NODE binaries (lastdb_server / folddb_server) that are NOT the brain
# pid. Deliberately do NOT match `fold-app`: the desktop brain (and its crash-reporter
# helper) run as fold-app and must never be classified as an orphan sweep candidate.
for pid in $(pgrep -f 'lastdb_server|folddb_server' 2>/dev/null); do
  [ "$pid" = "$BRAIN_PID" ] && continue
  # confirm it's really a *_server binary (pgrep -f false-positives on agent prompt text)
  CMD="$(ps -o command= -p "$pid" 2>/dev/null)"
  case "$CMD" in
    *lastdb_server*|*folddb_server*) : ;;
    *) continue ;;
  esac
  CWD="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  GONE=""
  if [ -n "$CWD" ] && [ ! -d "$CWD" ]; then GONE=" [cwd DELETED → safe to kill]"; fi
  warn "orphan test-node pid=$pid cwd=${CWD:-?}${GONE}"
  FOUND_ORPHAN=1
done
# run.sh dev harnesses reparented to launchd
for pid in $(pgrep -f 'run.sh --local' 2>/dev/null); do
  CWD="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  warn "dev harness run.sh pid=$pid cwd=${CWD:-?} (sweep ONLY if idle / temp --home & no live builder/client)"
  FOUND_ORPHAN=1
done
# stuck kanban hook ingest
for pid in $(pgrep -f 'kanban hooks ingest' 2>/dev/null); do
  warn "stuck kanban-hook-ingest pid=$pid (a hook should be instant; hours-old = leak, safe to kill if cwd gone)"
  FOUND_ORPHAN=1
done
if [ "$FOUND_ORPHAN" -eq 0 ]; then
  ok "No orphan folddb procs found."
else
  info "Rule: NEVER kill the primary-socket brain. Verify cwd is a deleted worktree / disposable temp home,"
  info "      and it does not hold $SOCKET / has no live builder, before killing. Surface-don't-act unattended."
fi

# ── 7. Disk (orphans + shared target are the usual hog) ──────────────────────
bold ""
bold "7. Disk"
DF="$(df -h /System/Volumes/Data 2>/dev/null | tail -1)"
if [ -n "$DF" ]; then
  USEP="$(echo "$DF" | awk '{print $5}' | tr -d '%')"
  AVAIL="$(echo "$DF" | awk '{print $4}')"
  if [ -n "$USEP" ] && [ "$USEP" -ge 92 ]; then
    bad "Data volume ${USEP}% used (avail $AVAIL) — disk pressure can mass-wedge agents."
    info "See machine-hygiene skill: cargo-sweep + orphan sweep. Don't cargo clean the shared target while agents build."
    bump 1
  else
    ok "Data volume ${USEP}% used (avail $AVAIL)."
  fi
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
bold ""
bold "════════════════════════════════════════════════════════════"
case "$STATUS" in
  0) bold " VERDICT: ✓ HEALTHY — brain is up and responsive on $SOCKET." ;;
  1) bold " VERDICT: ⚠ DEGRADED — usable but drift/partial-stall noted above. See ⚠ lines." ;;
  2) bold " VERDICT: ✗ WEDGED — full sled deadlock. kill -9 the PID, let launchd respawn (see §3)." ;;
  3) bold " VERDICT: ✗ DOWN — no socket at $SOCKET (see §1)." ;;
esac
bold "════════════════════════════════════════════════════════════"
exit "$STATUS"
