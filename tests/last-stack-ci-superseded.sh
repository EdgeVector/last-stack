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
STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-superseded-notoken.XXXXXX")"
cleanup() {
  if [[ -n "${MOCK_PID:-}" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$PORT_FILE" "$LOG_FILE"
  rm -rf "$STUB_DIR"
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

BRANCHES = {"main": {"name": "main", "commit": {"id": "dddd4444head"}}}

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))

    def do_GET(self):
        num = self.path.rsplit("/", 1)[-1]
        if self.headers.get("Authorization") != "token t":
            code, body = 401, {"message": "unauthorized"}
        elif "/branches/" in self.path and num in BRANCHES:
            code, body = 200, BRANCHES[num]
        elif "/branches/" in self.path:
            code, body = 404, {"message": "branch not found"}
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
# `FORGE_TOKEN=""` does NOT by itself reach the no-token branch. lib/forge-token.sh
# resolves three sources in order — $FORGE_TOKEN, keychain item `forgejo-token`,
# then lastsecrets://forgejo-token — so an empty env var only falls through to the
# next one. On a developer host the keychain answers, the binary reaches the mock,
# the mock 401s, and the answer is `unknown (no state/head in the PR reply)`. That
# made this one case green ONLY where every fallback is empty (the CI runner) and
# red for every agent running the same gate locally, which is the shape that
# teaches a fleet to ignore its own gate. Stub the two fallbacks so the branch
# under test is the branch that runs, in both environments.
printf '#!/bin/sh\nexit 1\n' >"$STUB_DIR/security"
printf '#!/bin/sh\nexit 1\n' >"$STUB_DIR/lastsecrets"
chmod +x "$STUB_DIR/security" "$STUB_DIR/lastsecrets"
FORGE_TOKEN="" PATH="$STUB_DIR:$PATH" expect 2 "no FORGE_TOKEN" --repo o/r --pr 1 --sha aaaa1111
# No assertion follows that the stubs did not leak into the later cases, and the
# reason is that one cannot be written honestly: every later case exports a real
# $FORGE_TOKEN, so it never consults a fallback and passes either way. A case
# that DID consult one would be environment-dependent again — exactly the defect
# above. The scoping rests on bash applying a prefix assignment to that one
# command only, which the two probes for this fix exercise directly.
# --branch: a main push run whose sha is no longer the head is superseded.
expect 1 "current — main is at dddd4444he" --repo o/r --branch main --sha dddd4444head
expect 0 "SUPERSEDED — main is now dddd4444he" --repo o/r --branch main --sha eeee5555old
expect 2 "no commit id" --repo o/r --branch gone --sha x
FORGE_ROOT="http://127.0.0.1:9" expect 2 "unknown" --repo o/r --branch main --sha x

echo "ok last-stack-ci-superseded"
