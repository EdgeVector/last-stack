#!/usr/bin/env bash
# Drive shipped last-stack-real-human-notify. REAL_HUMAN pages via ra notify;
# NOT_A_BLOCKER does not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-real-human-notify"
AUDIT="$ROOT/routines/human-gate-audit.md"
ESCALATE="$HOME/.claude/mcp/escalate-human/server.mjs"
chmod +x "$BIN"
python3 -m py_compile "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

: >"$tmp/ra.log"
cat >"$tmp/bin/ra" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${RA_LOG}"
exit 0
SH
chmod +x "$tmp/bin/ra"
export PATH="$tmp/bin:/usr/bin:/bin"
export RA_BIN="$tmp/bin/ra"
export RA_LOG="$tmp/ra.log"

cat >"$tmp/real.json" <<'EOF'
{
  "lines": [
    {
      "slug": "schema-pow-prod-enforcement",
      "bucket": "REAL_HUMAN",
      "status": "open",
      "actionable": true,
      "text": "flip prod gate after soak"
    }
  ]
}
EOF

cat >"$tmp/not.json" <<'EOF'
{
  "lines": [
    {
      "slug": "stale-needs-human-hold",
      "bucket": "NOT_A_BLOCKER",
      "status": "open",
      "actionable": true,
      "text": "agent can clear"
    }
  ]
}
EOF

# Two REAL_HUMAN dry-runs: must name ra notify.
python3 "$BIN" --input "$tmp/real.json" --dry-run --json >"$tmp/real1.json"
python3 "$BIN" --input "$tmp/real.json" --dry-run --json >"$tmp/real2.json"
python3 - "$tmp/real1.json" "$tmp/real2.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a["paged_count"] == 1 and b["paged_count"] == 1
argv = a["paged"][0]["ra_argv"]
assert argv[1] == "notify", argv
assert argv[3] == "--priority", argv
assert a["ra_shape"][:2] == ["ra", "notify"]
print("REAL_HUMAN dry-run uses ra notify")
PY
python3 "$BIN" --input "$tmp/real.json" --dry-run >"$tmp/real-dry.out" 2>"$tmp/real-dry.err"
grep -q 'WOULD' "$tmp/real-dry.err"
grep -q 'ra notify' "$tmp/real-dry.err"

# Live (fake ra) REAL_HUMAN actually invokes ra notify.
: >"$RA_LOG"
python3 "$BIN" --input "$tmp/real.json" --json >"$tmp/real-live.json"
grep -q 'notify' "$RA_LOG"
python3 - "$tmp/real-live.json" "$RA_LOG" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
log = open(sys.argv[2]).read()
assert r["paged_count"] == 1
assert "notify" in log
assert "--priority" in log
print("REAL_HUMAN live path invoked ra notify")
PY

# NOT_A_BLOCKER must not page.
: >"$RA_LOG"
python3 "$BIN" --input "$tmp/not.json" --dry-run --json >"$tmp/not.json.out"
python3 - "$tmp/not.json.out" "$RA_LOG" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
log = open(sys.argv[2]).read()
assert r["paged_count"] == 0, r
assert r["skipped"][0]["bucket"] == "NOT_A_BLOCKER"
assert "notify" not in log
print("NOT_A_BLOCKER does not page")
PY
python3 "$BIN" --input "$tmp/not.json" --dry-run >"$tmp/not-dry.out" 2>"$tmp/not-dry.err"
if grep -q 'WOULD' "$tmp/not-dry.err" "$tmp/not-dry.out"; then
  echo "NOT_A_BLOCKER must not print WOULD ra notify"
  exit 1
fi

grep -q 'last-stack-real-human-notify' "$AUDIT"
grep -q 'ra notify' "$AUDIT"
if [ -f "$ESCALATE" ]; then
  grep -qi 'does NOT notify' "$ESCALATE" \
    || grep -qi 'does not notify' "$ESCALATE" \
    || { echo "escalate MCP must still say it does not notify"; exit 1; }
fi

echo "last-stack-real-human-notify tests ok"
