#!/usr/bin/env bash
# Offline unit tests for last-stack-forge-runner-lanes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-forge-runner-lanes"
chmod +x "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- fixture: merge-gate home + heavy home (healthy) ---
mkdir -p "$tmp/merge" "$tmp/heavy" "$tmp/mixed"

cat >"$tmp/merge/.runner" <<'EOF'
{
  "id": 1,
  "name": "mac-forge-runner",
  "address": "http://localhost:3300",
  "labels": ["macos-arm64:host"]
}
EOF
cat >"$tmp/merge/config.yml" <<'EOF'
runner:
  capacity: 2
  labels:
    - macos-arm64:host
EOF

cat >"$tmp/heavy/.runner" <<'EOF'
{
  "id": 3,
  "name": "mac-forge-runner-host",
  "address": "http://localhost:3300",
  "labels": ["macos:host", "heavy:host"]
}
EOF
cat >"$tmp/heavy/config.yml" <<'EOF'
# Dedicated host-mode Forgejo runner for local release/deploy capacity.
runner:
  capacity: 1
  labels:
    - "macos:host"
    - "heavy:host"
EOF

# mixed: merge-gate home wrongly advertising heavy (must fail --check)
cat >"$tmp/mixed/.runner" <<'EOF'
{
  "id": 9,
  "name": "bad-merge",
  "labels": ["docker:docker://x", "heavy:host"]
}
EOF
cat >"$tmp/mixed/config.yml" <<'EOF'
runner:
  capacity: 3
  labels:
    - docker:docker://x
    - heavy:host
EOF

CFG="$ROOT/config/forge-runner-lanes.json"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

# Healthy pair
out="$("$BIN" --json --check --config "$CFG" --homes "$tmp/merge:$tmp/heavy")"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["heavy_ok"] is True, d
assert d["heavy_ok_local"] is True, d
assert d["merge_gate_has_heavy"] is False, d
assert d["separated_from_merge_gate"] is True, d
assert d["check_ok"] is True, d
assert d["merge_gate_unchanged"] is True, d
assert d["heavy_capacity"] >= 1, d
heavy=[r for r in d["local_runners"] if r["lane"]=="heavy"]
assert heavy and "heavy" in heavy[0]["labels"], heavy
print("healthy fixture ok")
'

# Human output path
hum="$("$BIN" --check --config "$CFG" --homes "$tmp/merge:$tmp/heavy")"
echo "$hum" | grep -q 'heavy_ok: true'
echo "$hum" | grep -q 'merge_gate_has_heavy: false'
echo "$hum" | grep -q 'check_ok: true'
echo "$hum" | grep -q 'merge_gate_unchanged: true'

# Missing heavy home -> check fails
set +e
"$BIN" --check --config "$CFG" --homes "$tmp/merge" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "expected check fail without heavy home" >&2; exit 1; }

# Mixed merge+heavy on same home -> check fails (not separated)
set +e
"$BIN" --check --config "$CFG" --homes "$tmp/mixed" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "expected check fail for mixed lane" >&2; exit 1; }

mixed_json="$("$BIN" --json --config "$CFG" --homes "$tmp/mixed" || true)"
echo "$mixed_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["merge_gate_has_heavy"] is True or d["check_ok"] is False, d
print("mixed fixture correctly rejected")
'

# Discover without --check always exits 0 even if incomplete
"$BIN" --config "$CFG" --homes "$tmp/merge" >/dev/null

# --- live: an offline runner is not a healthy lane ---
# papercut-forge-runner-lanes-check-ok-while-all-pc-runners-offline-20260922
PORT_FILE="$tmp/port"
python3 - "$PORT_FILE" "$tmp/scenario" <<'MOCK' >"$tmp/mock.log" 2>&1 &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_file, scenario_file = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        scen = open(scenario_file).read().strip()
        pc = "offline" if scen == "pc-down" else "idle"
        if self.path.startswith("/api/v1/admin/actions/runners"):
            body = [
                {"id": 1, "name": "mac-forge-runner", "status": "idle", "labels": ["macos-arm64"]},
                {"id": 2, "name": "pc-forge-runner", "status": pc, "labels": ["pc-linux", "docker"]},
                {"id": 3, "name": "pc-heavy-runner", "status": pc, "labels": ["heavy"]},
            ]
        else:
            body = []
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
MOCK
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$tmp"' EXIT
echo healthy >"$tmp/scenario"
for _ in $(seq 1 50); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
[ -s "$PORT_FILE" ] || { echo "mock did not start" >&2; cat "$tmp/mock.log" >&2; exit 1; }
live_env=(env FORGE_ROOT="http://127.0.0.1:$(cat "$PORT_FILE")" FORGE_TOKEN=test FORGE_ADMIN_TOKEN=test)

"${live_env[@]}" "$BIN" --json --check --live --repos EdgeVector/fold --config "$CFG" --homes "$tmp/merge:$tmp/heavy" >"$tmp/live-ok.json" \
  || { echo "healthy live fixture should pass --check" >&2; cat "$tmp/live-ok.json" >&2; exit 1; }
echo pc-down >"$tmp/scenario"
set +e
"${live_env[@]}" "$BIN" --json --check --live --repos EdgeVector/fold --config "$CFG" --homes "$tmp/merge:$tmp/heavy" >"$tmp/live-down.json"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "check_ok must fail with every PC runner offline" >&2; cat "$tmp/live-down.json" >&2; exit 1; }
python3 - "$tmp/live-down.json" <<'CHK'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["live"]["ok"] is True, d["live"]
assert d["heavy_ok_live"] is False, d
assert d["check_ok"] is False, d
assert d["live"]["merge_gate_expected_offline"] == ["pc-forge-runner"], d["live"]
print("live offline fixture correctly rejected")
CHK

echo "ok last-stack-forge-runner-lanes"
