#!/usr/bin/env bash
# Unit tests for leftover folddb.sock health wait (2026-08-26).
# A stale inode without a listener is not healthy. Unlink only if no listener.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/live-socket-health.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
chmod +x "$CHECKS" 2>/dev/null || true

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/live-socket-health.sh
. "$CHECKS"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-live-sock-test.XXXXXX")"
HTTP_PID=""
LISTEN_PID=""
cleanup() {
  if [ -n "$HTTP_PID" ]; then kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; fi
  if [ -n "$LISTEN_PID" ]; then kill "$LISTEN_PID" 2>/dev/null || true; wait "$LISTEN_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

cat >"$TMP/make_stale.py" <<'PY'
import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY

cat >"$TMP/listen_only.py" <<'PY'
import os, signal, socket, sys, time
path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
print("ready", flush=True)
signal.pause()
PY

cat >"$TMP/http_ok.py" <<'PY'
import http.server
import os
import signal
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)
    def log_message(self, *_args):
        return

class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True

path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
httpd = UnixHTTPServer(path, Handler)
print("ready", flush=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
httpd.serve_forever()
PY

# --- missing path is not a listener and is not healthy ----------------------
missing="$TMP/no-such.sock"
live_unix_socket_has_listener "$missing" && fail "missing path must not have a listener"
live_unix_socket_is_healthy "$missing" && fail "missing path must not be healthy"
out="$(unlink_stale_unix_socket "$missing")"
printf '%s\n' "$out" | grep -q 'LIVE_SOCK=absent' || fail "missing path unlink: $out"

# --- leftover inode: -S true, no listener, not healthy, unlink it -----------
stale="$TMP/stale.sock"
python3 "$TMP/make_stale.py" "$stale"
[ -S "$stale" ] || fail "stale fixture must be a socket inode"
live_unix_socket_has_listener "$stale" && fail "leftover inode must not count as a listener"
live_unix_socket_is_healthy "$stale" && fail "leftover inode must not be healthy"
out="$(unlink_stale_unix_socket "$stale")"
printf '%s\n' "$out" | grep -q 'LIVE_SOCK=unlinked' || fail "leftover must unlink: $out"
[ ! -e "$stale" ] || fail "leftover inode must be gone after unlink"

# wait_for on a leftover: unlinks, then unhealthy (poll 0 so no sleep)
python3 "$TMP/make_stale.py" "$stale"
export LASTDB_LIVE_SOCK_POLL_SECS=0
set +e
wait_out="$(wait_for_live_unix_socket_health "$stale" 0 2>"$TMP/wait.err")"
wait_rc=$?
set -e
[ "$wait_rc" -ne 0 ] || fail "wait_for leftover inode must fail; out=$wait_out"
printf '%s\n' "$wait_out" | grep -q 'LIVE_SOCK=unlinked' || fail "wait_for must unlink leftover: $wait_out"
grep -q 'LIVE_SOCK=unhealthy' "$TMP/wait.err" || fail "wait_for leftover must report unhealthy: $(cat "$TMP/wait.err")"
[ ! -e "$stale" ] || fail "wait_for must have unlinked the leftover"

# --- live listener without HTTP: keep the inode, health fails ---------------
listen="$TMP/listen.sock"
python3 "$TMP/listen_only.py" "$listen" >"$TMP/listen.ready" 2>&1 &
LISTEN_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q ready "$TMP/listen.ready" 2>/dev/null && break
  sleep 0.1
done
[ -S "$listen" ] || fail "listen-only fixture must exist"
live_unix_socket_has_listener "$listen" || fail "listen-only socket must have a listener pid"
live_unix_socket_is_healthy "$listen" && fail "listen-only socket must not pass /health"
out="$(unlink_stale_unix_socket "$listen")"
printf '%s\n' "$out" | grep -q 'LIVE_SOCK=keep' || fail "must not unlink a live listener: $out"
[ -S "$listen" ] || fail "live listener socket must still exist"
kill "$LISTEN_PID" 2>/dev/null || true
wait "$LISTEN_PID" 2>/dev/null || true
LISTEN_PID=""
rm -f "$listen"

# --- HTTP /health ok: healthy, keep, wait_for succeeds immediately ----------
ok="$TMP/ok.sock"
python3 "$TMP/http_ok.py" "$ok" >"$TMP/http.ready" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q ready "$TMP/http.ready" 2>/dev/null && break
  sleep 0.1
done
[ -S "$ok" ] || fail "http fixture must exist"
live_unix_socket_has_listener "$ok" || fail "http socket must have a listener"
live_unix_socket_health_ok "$ok" || fail "http socket /health must be ok"
live_unix_socket_is_healthy "$ok" || fail "http socket must be healthy"
out="$(unlink_stale_unix_socket "$ok")"
printf '%s\n' "$out" | grep -q 'LIVE_SOCK=keep' || fail "must keep a healthy listener: $out"
set +e
wait_out="$(wait_for_live_unix_socket_health "$ok" 0 2>"$TMP/wait-ok.err")"
wait_rc=$?
set -e
[ "$wait_rc" -eq 0 ] || fail "wait_for healthy socket must succeed; out=$wait_out err=$(cat "$TMP/wait-ok.err")"
printf '%s\n' "$wait_out" | grep -q 'LIVE_SOCK=healthy after_s=0' || fail "healthy wait: $wait_out"
[ -S "$ok" ] || fail "healthy wait must not unlink a live listener"

# --- driver wiring ----------------------------------------------------------
grep -q 'live-socket-health.sh' "$DRIVER" || fail "driver must source live-socket-health.sh"
grep -q 'wait_for_live_unix_socket_health' "$DRIVER" || fail "driver must wait for listener + /health"
grep -q 'live_unix_socket_is_healthy' "$DRIVER" || fail "driver post-check must use live_unix_socket_is_healthy"
if grep -n 'while \[ ! -S "\$PRIMARY_SOCK" \]' "$DRIVER" >/dev/null; then
  fail "driver still waits only for a socket inode"
fi
grep -q 'leftover' "$SKILL_MD" || fail "SKILL.md must name leftover socket inodes"

echo "PASS: leftover folddb.sock without a listener is not healthy; unlink only if no listener"
