#!/usr/bin/env bash
# Fixture test for bin/last-stack-kanban-pickup-zero-llm-gate. Fake stock gate,
# fake kickoff and fake heartbeat appender; no board, no loom, no brain.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-pickup-zero-llm-gate"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/zero-llm-gate-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/runs/last-stack-fkanban-pickup-w9/run1" "$tmp/kickoffs"
cat >"$tmp/gate" <<'EOF'
#!/usr/bin/env bash
echo "gate-called" >>"$FIXTURE_DIR/calls"
if [ "$GATE_RC" = 0 ]; then echo "ROUTINE_RESULT outcome=noop detail=ready=0"; fi
exit "$GATE_RC"
EOF
cat >"$tmp/kick" <<'EOF'
#!/usr/bin/env bash
echo "kick-called" >>"$FIXTURE_DIR/calls"
echo "claim log line"
echo "ROUTINE_RESULT outcome=ok detail=worked=card-a result=loom-started"
EOF
cat >"$tmp/hb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"$FIXTURE_DIR/heartbeats"
EOF
chmod +x "$tmp/gate" "$tmp/kick" "$tmp/hb"

run() {
  : >"$tmp/calls"
  FIXTURE_DIR="$tmp" GATE_RC="$1" \
    LAST_STACK_PICKUP_GATE="$tmp/gate" LOOM_KICKOFF="$tmp/kick" \
    LAST_STACK_HEARTBEAT_BIN="$tmp/hb" LOOM_KICKOFF_LOG_ROOT="$tmp/kickoffs" \
    ROUTINES_RUN_DIR="$tmp/runs/last-stack-fkanban-pickup-w9/run1" \
    "$BIN" >"$tmp/out" 2>&1 && rc=0 || rc=$?
}

# 1. Gate skips (ready=0) and the worker holds no walk: pass through, no kickoff.
run 0
[ "$rc" = 0 ] || fail "skip rc=$rc"
grep -q kick-called "$tmp/calls" && fail "kickoff ran on a gate skip"
grep -q 'outcome=noop' "$tmp/out" || fail "skip trailer missing"

# 2. Gate proceeds: the kickoff runs, one trailer, a heartbeat, exit 0 (harness skipped).
run 10
[ "$rc" = 0 ] || fail "proceed rc=$rc"
grep -q kick-called "$tmp/calls" || fail "kickoff did not run on proceed"
[ "$(grep -c '^ROUTINE_RESULT ' "$tmp/out")" = 1 ] || fail "want exactly one trailer: $(cat "$tmp/out")"
tail -1 "$tmp/out" | grep -q 'result=loom-started' || fail "trailer is not the kickoff outcome"
grep -q '^kanban-pickup .* land-card outcome=ok' "$tmp/heartbeats" || fail "heartbeat missing"

# 3. The worker holds a walk state file: resume it even when the gate would skip.
echo "key card 999999 {}" >"$tmp/kickoffs/last-stack-fkanban-pickup-w9.current"
run 0
[ "$rc" = 0 ] || fail "resume rc=$rc"
grep -q kick-called "$tmp/calls" || fail "held walk was not resumed"
grep -q gate-called "$tmp/calls" && fail "gate ran although a walk is held"
rm -f "$tmp/kickoffs/last-stack-fkanban-pickup-w9.current"

# 4. Stock gate config error passes through.
run 2
[ "$rc" = 2 ] || fail "config error rc=$rc"

# 5. No ROUTINES_RUN_DIR: refuse, so workers never share the default state file.
env -u ROUTINES_RUN_DIR LAST_STACK_PICKUP_GATE="$tmp/gate" LOOM_KICKOFF="$tmp/kick" \
  LOOM_KICKOFF_LOG_ROOT="$tmp/kickoffs" "$BIN" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "missing run dir rc=$rc"

echo "ok: last-stack-kanban-pickup-zero-llm-gate"
