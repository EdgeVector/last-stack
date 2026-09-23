#!/usr/bin/env bash
# last-stack-ci-superseded: a PR run on a merged, closed or replaced head must
# answer superseded (exit 0); a current head answers 1; anything it cannot read
# answers 2, so the gate runs (fail-open).
# papercut-forge-queued-runs-for-merged-pr-heads-cannot-be-cancelled-by-agents-20260923
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-ci-superseded"
test -x "$BIN"

PORT_FILE="$(mktemp "${TMPDIR:-/tmp}/ci-superseded-port.XXXXXX")"
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/ci-superseded-mock.XXXXXX")"
cleanup() {
  if [[ -n "${MOCK_PID:-}" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$PORT_FILE" "$LOG_FILE"
}
trap cleanup EXIT

python3 - "$PORT_FILE" <<'PY' >"$LOG_FILE" 2>&1 &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PULLS = {
    "1": {"state": "open", "merged": False, "head": {"sha": "aaaa1111"}},
    "2": {"state": "closed", "merged": True, "head": {"sha": "bbbb2222"}},
    "3": {"state": "open", "merged": False, "head": {"sha": "cccc3333new"}},
}

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))

    def do_GET(self):
        num = self.path.rsplit("/", 1)[-1]
        if self.headers.get("Authorization") != "token t":
            code, body = 401, {"message": "unauthorized"}
        elif num in PULLS:
            code, body = 200, PULLS[num]
        else:
            code, body = 200, {"message": "not a PR"}
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

httpd = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.05; done
[[ -s "$PORT_FILE" ]] || { echo "FAIL: mock did not start" >&2; cat "$LOG_FILE" >&2; exit 1; }
export FORGE_ROOT="http://127.0.0.1:$(cat "$PORT_FILE")"
export FORGE_TOKEN="t"

expect() {  # want-rc want-substring args...
  local want="$1" sub="$2" out rc=0
  shift 2
  out="$("$BIN" "$@")" || rc=$?
  if [[ "$rc" -ne "$want" || "$out" != *"$sub"* ]]; then
    echo "FAIL: $* -> rc=$rc (want $want) out=$out (want *$sub*)" >&2
    exit 1
  fi
}

expect 1 "current" --repo o/r --pr 1 --sha aaaa1111
expect 0 "SUPERSEDED — PR #2 is closed (merged=true)" --repo o/r --pr 2 --sha bbbb2222
expect 0 "head is now cccc3333ne" --repo o/r --pr 3 --sha cccc3333old
expect 2 "no state/head" --repo o/r --pr 9 --sha x
expect 2 "no PR number" --repo o/r --pr "" --sha x
FORGE_TOKEN="wrong" expect 2 "unknown" --repo o/r --pr 1 --sha aaaa1111
FORGE_ROOT="http://127.0.0.1:9" expect 2 "unknown" --repo o/r --pr 1 --sha aaaa1111
FORGE_TOKEN="" expect 2 "no FORGE_TOKEN" --repo o/r --pr 1 --sha aaaa1111

echo "ok last-stack-ci-superseded"
