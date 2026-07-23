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

echo "ok last-stack-forge-runner-lanes"
