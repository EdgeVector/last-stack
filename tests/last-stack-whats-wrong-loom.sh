#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-whats-wrong-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-whats-wrong-routine"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-list.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh"
bash -n "$ROOT/lib/whats-wrong/loom-whats-wrong-closeout.sh"

[ -f "$ROOT/routines/whats-wrong.md" ] || fail "whats-wrong prompt missing"
grep -q 'last-stack-whats-wrong-loom' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing loom hook"
grep -q 'Close-out (always the LAST step)' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing close-out section"
grep -q 'coverage.exceptions' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing snapshot field"

[ -f "$ROOT/lib/whats-wrong/whats-wrong.json" ] || fail "lib graph missing"
[ -f "$ROOT/lib/whats-wrong/whats-wrong-item.json" ] || fail "lib item graph missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/snap.json" <<'JSON'
{"coverage":{"exceptions":[
  {"id":"ship.why-stopped-loom","label":"why-loom","L":"x","F":" ","T":"x","why":"stale"},
  {"id":"machine.disk-lastdb","label":"Disk","L":" ","F":" ","T":"x","why":"full"}
]}}
JSON

export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp.json"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ship.why-stopped-loom' || fail "dry-run json missing why-loom: $out"
printf '%s\n' "$out" | grep -q 'machine.disk-lastdb' || fail "dry-run json missing disk: $out"
printf '%s\n' "$out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("count")==2, d'

empty="$tmp/empty.json"
printf '%s\n' '{"coverage":{"exceptions":[]}}' >"$empty"
WHATS_WRONG_SNAPSHOT_FILE="$empty" empty_out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$empty_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("count")==0, d'

# stand-in heal (no live agent)
WHATS_WRONG_SKIP_BRAIN=1 LOOM_INPUT='{"item":{"id":"x","label":"X"}}' \
  "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh" | grep -q 'stand-in' \
  || fail "heal stand-in missing"

# mechanical load path (no grok)
mech_out="$(
  LOOM_WHATS_WRONG_LIVE=1 WHATS_WRONG_MECHANICAL_ONLY=1 \
    LOOM_INPUT='{"item":{"id":"machine.load","label":"CPU load"}}' \
    "$ROOT/lib/whats-wrong/loom-whats-wrong-heal.sh"
)"
printf '%s\n' "$mech_out" | grep -q 'mechanical' || fail "mechanical heal missing: $mech_out"
printf '%s\n' "$mech_out" | python3 -c 'import json,sys
d=None
for line in sys.stdin:
    line=line.strip()
    if line.startswith("{") and "heal_status" in line:
        d=json.loads(line)
assert d and d.get("id")=="machine.load" and d.get("heal_status") in ("healed","noop"), d'

# --- no loom → exit 3 ---
set +e
HOME="$tmp" PATH="/usr/bin:/bin" LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp2.json" \
  "$BIN" --json --quiet >"$tmp/noloom.out" 2>"$tmp/noloom.err"
nrc=$?
set -e
[ "$nrc" -eq 3 ] || fail "expected exit 3 without loom, got $nrc $(cat "$tmp/noloom.err")"

# --- mock loom run ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    cat <<'VIEW'
lx-ww-1
lx-ww-1
status: succeeded
state: DONE
context.outcome: "ok"
context.detail: "exceptions=2 healed=1 remaining=1"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp3.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-test-key"
set +e
mout="$("$BIN" --json --quiet --no-heal)"
mrc=$?
set -e
[ "$mrc" -eq 0 ] || fail "mock loom exit $mrc: $mout"
printf '%s\n' "$mout" | grep -q '"outcome":"ok"' || fail "json missing outcome=ok: $mout"
printf '%s\n' "$mout" | grep -q 'exceptions=2' || fail "json missing detail: $mout"
printf '%s\n' "$mout" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $mout"

# --- hung loom child is SIGTERM'd; wrapper still emits ROUTINE_RESULT ---
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    printf '%s\n' "$$" >"${HANG_PID_FILE:?}"
    exec sleep 86400
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export LAST_STACK_WHATS_WRONG_STAMP="$tmp/stamp-hang.json"
export LAST_STACK_WHATS_WRONG_LOOM_TIMEOUT_SEC=1
export HANG_PID_FILE="$tmp/hang.pid"
export WHATS_WRONG_SNAPSHOT_FILE="$tmp/snap.json"
export LOOM_WHATS_WRONG_KEY="whats-wrong-hang-key"
hang_start="$(date +%s)"
set +e
hout="$("$BIN" --json --quiet --no-heal)"
hrc=$?
hang_end="$(date +%s)"
set -e
hang_sec=$((hang_end - hang_start))
[ "$hang_sec" -lt 20 ] || fail "hung loom wrapper took ${hang_sec}s, expected <20"
[ "$hrc" -eq 3 ] || fail "hung loom should exit 3, got $hrc out=$hout"
printf '%s\n' "$hout" | grep -q 'ROUTINE_RESULT' || fail "hung loom missing ROUTINE_RESULT: $hout"
printf '%s\n' "$hout" | grep -q 'outcome=error' || fail "hung loom missing outcome=error: $hout"
printf '%s\n' "$hout" | grep -q 'exceptions=2' || fail "hung loom missing exceptions count: $hout"
printf '%s\n' "$hout" | grep -q 'healed=0' || fail "hung loom missing healed count: $hout"
printf '%s\n' "$hout" | grep -q 'loom-timeout=' || fail "hung loom missing timeout marker: $hout"
if [ -f "$tmp/hang.pid" ]; then
  hpid="$(cat "$tmp/hang.pid")"
  if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
    kill -9 "$hpid" 2>/dev/null || true
    fail "hung loom pid $hpid still alive after wrapper"
  fi
else
  fail "hung loom did not write pid file"
fi

echo "ok"
