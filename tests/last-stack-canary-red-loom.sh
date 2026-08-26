#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-red-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-canary-red-heal-routine"
bash -n "$ROOT/lib/canary-red/loom-canary-collect.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-heal.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-report.sh"

[ -f "$ROOT/routines/lastdb-canary-red-heal.md" ] || fail "canary-red-heal prompt missing"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing loom wrapper"
grep -q 'Close-out (always the LAST step)' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing close-out section"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch prompt missing canary-red hook"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood prompt missing canary-red hook"
grep -q 'NEVER skip the probe latency bar' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing probe-bar rule"

[ -f "$ROOT/lib/canary-red/canary-red-heal.json" ] || fail "lib graph missing"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$ROOT/lib/canary-red/canary-red-heal.json" \
  || fail "lib graph is not JSON"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-red.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/sm-list.json" <<'JSON'
[
  {
    "id": "exec_old",
    "definition": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updatedAt": "2020-01-01T00:00:00.000Z"
  },
  {
    "id": "exec_new",
    "definition": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updatedAt": "2099-01-01T00:00:00.000Z"
  }
]
JSON

export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp.json"
export CANARY_RED_SM_LIST_FILE="$tmp/sm-list.json"

out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'exec_new' || fail "dry-run json missing newest fail: $out"
printf '%s\n' "$out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("idle") is False and d.get("exec_id")=="exec_new", d'

cat >"$tmp/sm-idle.json" <<'JSON'
[{"id":"exec_run","status":"running","state":"SOAK_WAIT","updatedAt":"2099-01-01T00:00:00.000Z"}]
JSON
idle_out="$(CANARY_RED_SM_LIST_FILE="$tmp/sm-idle.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$idle_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="lane_busy", d'

printf '%s\n' '[]' >"$tmp/empty.json"
empty_out="$(CANARY_RED_SM_LIST_FILE="$tmp/empty.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$empty_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True, d'

# stand-in scripts (no live agent)
cat >"$tmp/get.json" <<'JSON'
{"id":"exec_test","status":"failed","state":"FAILED","inputJson":"{\"main_oid\":\"abc\"}","contextJson":"{\"source_git_oid\":\"abc\",\"version\":\"0.1\"}"}
JSON
stand="$(
  LOOM_INPUT='{"exec_id":"exec_test","max_attempts":3}' \
  CANARY_RED_SM_GET_FILE="$tmp/get.json" \
    "$ROOT/lib/canary-red/loom-canary-collect.sh"
)"
printf '%s\n' "$stand" | grep -q 'verdict":"red"' || fail "collect stand-in missing red: $stand"
printf '%s\n' "$stand" | grep -q PASS || fail "collect missing PASS"

LOOM_IDEMPOTENCY_KEY=test-key LOOM_INPUT='{"exec_id":"exec_test","attempt":0}' \
  "$ROOT/lib/canary-red/loom-canary-heal.sh" | grep -q 'stand-in' \
  || fail "heal stand-in missing"

LOOM_INPUT='{"heal_status":"stand-in","attempt":2,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh" | grep -q 'exhausted' \
  || fail "retry stand-in missing exhausted at attempt 3"

CANARY_RED_SKIP_BRAIN=1 LOOM_INPUT='{"exec_id":"exec_test","verdict":"exhausted","attempt":3,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-report.sh" | grep -q PASS \
  || fail "report stand-in missing PASS"

# --- no loom → exit 3 ---
set +e
HOME="$tmp" PATH="/usr/bin:/bin" LAST_STACK_CANARY_RED_STAMP="$tmp/stamp2.json" \
  CANARY_RED_SM_LIST_FILE="$tmp/sm-list.json" \
  "$BIN" --json --quiet --no-heal >"$tmp/noloom.out" 2>"$tmp/noloom.err"
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
lx-canary-1
status: succeeded
state: DONE
context.verdict: "green"
context.heal_status: "fixed"
context.attempt: 1
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp3.json"
export CANARY_RED_SM_LIST_FILE="$tmp/sm-list.json"
export LOOM_CANARY_RED_KEY="canary-red-test-key"
set +e
mout="$("$BIN" --json --quiet --no-heal)"
mrc=$?
set -e
[ "$mrc" -eq 0 ] || fail "mock loom exit $mrc: $mout"
printf '%s\n' "$mout" | grep -q '"outcome":"ok"' || fail "json missing outcome=ok: $mout"
printf '%s\n' "$mout" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $mout"
printf '%s\n' "$mout" | grep -q 'verdict=green' || fail "missing verdict=green: $mout"

echo "ok"
