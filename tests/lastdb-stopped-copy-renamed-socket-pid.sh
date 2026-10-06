#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/live-socket-health.sh"
COPY_HELPER="$ROOT/skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh"
bash -n "$CHECKS" "$COPY_HELPER"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh
. "$COPY_HELPER"

TEST_ROOT="$(mktemp -d /tmp/lastdb-renamed-socket.XXXXXX)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cat >"$TEST_ROOT/server.py" <<'PY'
import http.server
import json
import os
import socketserver
import sys

path, mode_path, ready_path = sys.argv[1:]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        mode = open(mode_path, encoding="utf-8").read().strip()
        status = "bad" if mode == "unhealthy" else "ok"
        instance_id = f"{os.getpid()}-123"
        if mode == "forged":
            instance_id = "999999-123"
        if mode == "malformed":
            instance_id = "not-a-pid"
        body = json.dumps({"status": status, "api_version": 1,
                           "instance_id": instance_id}, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return

class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True

server = UnixHTTPServer(path + ".tmp", Handler)
os.rename(path + ".tmp", path)
open(ready_path, "w", encoding="utf-8").write("ready\n")
server.serve_forever()
PY

sock="$TEST_ROOT/folddb.sock"
mode="$TEST_ROOT/mode"
ready="$TEST_ROOT/ready"
printf 'ok\n' >"$mode"
python3 "$TEST_ROOT/server.py" "$sock" "$mode" "$ready" >"$TEST_ROOT/server.out" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$ready" ] && break
  sleep 0.1
done
[ -S "$sock" ] && [ -f "$ready" ] \
  || { printf 'FAIL: renamed socket server did not start\n' >&2; exit 1; }

# Simulate macOS lsof, which retains the original .tmp name after rename.
lsof() { return 1; }
pid="$(live_unix_socket_health_pid "$sock")"
[ "$pid" = "$SERVER_PID" ] \
  || { printf 'FAIL: renamed socket health PID differs from the live server\n' >&2; exit 1; }
pid="$(live_unix_socket_listener_pid "$sock")"
[ "$pid" = "$SERVER_PID" ] \
  || { printf 'FAIL: renamed socket listener PID has no health fallback\n' >&2; exit 1; }

EXPECTED_JOB_PID="$SERVER_PID"
lastdb_launchd_job_pid() { printf '%s\n' "$EXPECTED_JOB_PID"; }
lastdb_require_supervised_primary() { [ "${3:-}" = "$EXPECTED_JOB_PID" ]; }
primary_is_supervised_and_healthy gui/501 com.test.lastdbd "$sock" \
  || { printf 'FAIL: renamed socket rejected the matching supervised PID\n' >&2; exit 1; }

EXPECTED_JOB_PID=999998
if primary_is_supervised_and_healthy gui/501 com.test.lastdbd "$sock"; then
  printf 'FAIL: wrong launchd PID passed the socket identity gate\n' >&2; exit 1
fi
EXPECTED_JOB_PID="$SERVER_PID"

printf 'forged\n' >"$mode"
if primary_is_supervised_and_healthy gui/501 com.test.lastdbd "$sock"; then
  printf 'FAIL: forged health PID passed the supervised PID gate\n' >&2; exit 1
fi
printf 'malformed\n' >"$mode"
if live_unix_socket_health_pid "$sock" >/dev/null; then
  printf 'FAIL: malformed health instance ID produced a PID\n' >&2; exit 1
fi
printf 'unhealthy\n' >"$mode"
if live_unix_socket_health_pid "$sock" >/dev/null; then
  printf 'FAIL: unhealthy socket produced a PID\n' >&2; exit 1
fi

printf 'PASS: renamed socket PID matches launchd; wrong and malformed IDs fail\n'
