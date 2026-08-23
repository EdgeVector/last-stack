#!/usr/bin/env bash
# Compound prevention: last-stack-forge-api must surface HTTP error bodies on
# non-2xx (esp. Forgejo auto-merge 409 while checks pending). Never collapse to
# opaque curl: (22) from curl -f.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
API="$ROOT/bin/last-stack-forge-api"
test -x "$API"

# Guard: the wrapper must not pass curl -f (the historical body-loss bug).
if grep -E 'curl_args=\(.*-f' "$API" >/dev/null 2>&1 || grep -E 'curl .*-[a-zA-Z]*f[a-zA-Z]*' "$API" | grep -v 'http_code\|write-out\|%' >/dev/null 2>&1; then
  # Allow -fsS only if we still document the ban; hard-fail on -f in curl_args assignment.
  if grep -n 'curl_args=.*-f' "$API" | grep -v '^\s*#' >/dev/null 2>&1; then
    echo "FAIL: last-stack-forge-api still builds curl_args with -f (body loss on 4xx/5xx)" >&2
    exit 1
  fi
fi
if grep -E 'curl_args=\(-fsS|curl_args=\(-f' "$API" >/dev/null 2>&1; then
  echo "FAIL: last-stack-forge-api curl_args still uses -f / -fsS" >&2
  exit 1
fi

PORT_FILE="$(mktemp "${TMPDIR:-/tmp}/forge-api-port.XXXXXX")"
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/forge-api-mock.XXXXXX")"
BODY409='{"message":"merge blocked by required status checks","errors":["ci-required is pending"],"pending_merge":null}'
BODY200='{"ok":true,"pending_merge":true}'

cleanup() {
  if [[ -n "${MOCK_PID:-}" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$PORT_FILE" "$LOG_FILE"
}
trap cleanup EXIT

# Minimal HTTP mock: 409 on merge POST, 200 on GET /ok
python3 - "$PORT_FILE" "$BODY409" "$BODY200" <<'PY' >"$LOG_FILE" 2>&1 &
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, body409, body200 = sys.argv[1], sys.argv[2], sys.argv[3]

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # Any non-merge GET is success — proves 2xx still prints body.
        if "/merge" in self.path:
            self._send(405, json.dumps({"message": "method not allowed"}))
        elif self.path.endswith("/pulls/405"):
            self._send(200, json.dumps({"number": 405, "mergeable": False, "state": "open"}))
        elif self.path.endswith("/pulls/406"):
            self._send(200, json.dumps({"number": 406, "mergeable": True, "state": "open"}))
        else:
            self._send(200, body200)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        _ = self.rfile.read(length) if length else b""
        if self.path.endswith("/pulls/405/merge"):
            # Forgejo's real 405 body. It reads as transient and names nothing.
            self._send(405, json.dumps({"message": "Please try again later"}))
        elif self.path.endswith("/pulls/406/merge"):
            self._send(405, json.dumps({"message": "Please try again later"}))
        elif "/merge" in self.path:
            # Simulate Forgejo auto-merge arm while required checks pending.
            self._send(409, body409)
        else:
            self._send(200, body200)

httpd = HTTPServer(("127.0.0.1", 0), H)
host, port = httpd.server_address
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(port))
sys.stderr.write("mock listening on %s\n" % port)
httpd.serve_forever()
PY
MOCK_PID=$!

# Wait for port file
for _ in $(seq 1 50); do
  if [[ -s "$PORT_FILE" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -s "$PORT_FILE" ]]; then
  echo "FAIL: mock server did not publish port" >&2
  cat "$LOG_FILE" >&2 || true
  exit 1
fi
PORT="$(cat "$PORT_FILE")"
export FORGE_ROOT="http://127.0.0.1:${PORT}"
export FORGE_TOKEN="test-token-not-secret"

# --- Case 1: non-2xx must print body + exit non-zero (never curl: (22) alone) ---
set +e
err_out="$("$API" --method POST \
  --data '{"Do":"merge","merge_when_checks_succeed":true}' \
  repos/EdgeVector/fold/pulls/999/merge 2>&1 >/dev/null)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit on HTTP 409, got 0" >&2
  echo "stderr/out: $err_out" >&2
  exit 1
fi
if [[ "$err_out" == *"curl: (22)"* ]] && [[ "$err_out" != *"merge blocked"* ]]; then
  echo "FAIL: opaque curl (22) without forge body" >&2
  echo "got: $err_out" >&2
  exit 1
fi
if [[ "$err_out" != *"HTTP 409"* ]]; then
  echo "FAIL: missing HTTP 409 status line on stderr" >&2
  echo "got: $err_out" >&2
  exit 1
fi
if [[ "$err_out" != *"merge blocked by required status checks"* ]]; then
  echo "FAIL: response body not surfaced on stderr" >&2
  echo "got: $err_out" >&2
  exit 1
fi
if [[ "$err_out" != *"ci-required is pending"* ]]; then
  echo "FAIL: named blocker missing from body" >&2
  echo "got: $err_out" >&2
  exit 1
fi

# --- Case 2: 2xx still succeeds and prints body ---
ok_out="$("$API" repos/EdgeVector/fold/ok)"
if [[ "$ok_out" != *'"pending_merge":true'* ]] && [[ "$ok_out" != *'"ok":true'* ]]; then
  echo "FAIL: 2xx path did not return body" >&2
  echo "got: $ok_out" >&2
  exit 1
fi

# --- Case 3: a merge 405 must say WHICH 405 it is ---
# Forgejo answers 405 {"message":"Please try again later"} both for a stuck
# status-check task (heal: empty commit) and for a branch that genuinely does
# not merge (heal: rebuild). Only `mergeable` separates them, and reading the
# body alone sends you to the wrong heal — see brain
# `papercut-lastgit-merge-405-can-mean-unmergeable-not-a-stuck-status-check`.
set +e
conflict_out="$("$API" --method POST --data '{"Do":"squash"}' \
  repos/EdgeVector/fold/pulls/405/merge 2>&1 >/dev/null)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit on HTTP 405, got 0" >&2
  exit 1
fi
if [[ "$conflict_out" != *"Please try again later"* ]]; then
  echo "FAIL: 405 body no longer surfaced" >&2
  echo "got: $conflict_out" >&2
  exit 1
fi
if [[ "$conflict_out" != *"mergeable=false"* || "$conflict_out" != *"REAL CONFLICT"* ]]; then
  echo "FAIL: 405 on an unmergeable PR did not name mergeable=false" >&2
  echo "got: $conflict_out" >&2
  exit 1
fi
if [[ "$conflict_out" != *"empty-commit heal cannot fix it"* ]]; then
  echo "FAIL: 405 verdict did not rule out the documented heal" >&2
  echo "got: $conflict_out" >&2
  exit 1
fi

set +e
stuck_out="$("$API" --method POST --data '{"Do":"squash"}' \
  repos/EdgeVector/fold/pulls/406/merge 2>&1 >/dev/null)"
set -e
if [[ "$stuck_out" != *"mergeable=true"* || "$stuck_out" != *"empty-commit heal applies"* ]]; then
  echo "FAIL: 405 on a mergeable PR did not point at the stuck status-check heal" >&2
  echo "got: $stuck_out" >&2
  exit 1
fi

# --- Case 4: the verdict must not fire on any other failure ---
# A 409 auto-merge arm is a different condition with a different remedy; adding
# a merge-conflict line to it would be the same confusion in reverse.
if [[ "$err_out" == *"mergeable="* ]]; then
  echo "FAIL: 409 path emitted a 405 mergeable verdict" >&2
  echo "got: $err_out" >&2
  exit 1
fi

echo "ok last-stack-forge-api error-body + 2xx path + 405 mergeable partition"
