#!/usr/bin/env bash
# Job-shrink-gate must invoke the shipped helper, not stamp a hardcoded skip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-routine-job-shrink-gate"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -x "$bin" ] || fail "missing $bin"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/job-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${JOB_GATE_LOG}"
if [ "${1:-}" = "groom" ] && [ "${2:-}" = "parity-check" ]; then
  echo '{"ok":true}'
  exit 0
fi
exit 2
SH
chmod +x "$tmp/bin/kanban"
export PATH="$tmp/bin:/usr/bin:/bin"
export JOB_GATE_FIXTURE=1
export JOB_GATE_LOG="$tmp/kanban.args"

out="$("$bin" kanban-parity-check)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok' || fail "parity gate: $out"
grep -qx 'groom parity-check --json' "$JOB_GATE_LOG" || fail "did not invoke kanban groom parity-check --json: $(cat "$JOB_GATE_LOG")"

# Stub the runner so the unit test never touches the live board.
cat >"$tmp/bin/last-stack-card-reaper-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'ROUTINE_RESULT outcome=ok detail=fixture=1'
exit 0
SH
chmod +x "$tmp/bin/last-stack-card-reaper-run"
out="$("$bin" last-stack-card-reaper)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok detail=fixture=1' || fail "stub reaper: $out"

# Missing helper is error, not a fake ok.
out="$(CARD_REAPER_RUN="$tmp/no-such-reaper" "$bin" last-stack-card-reaper 2>&1 || true)"
case "$out" in
  *ROUTINE_RESULT\ outcome=error*|*card-reaper-run-missing*) ;;
  *) fail "missing reaper should error: $out" ;;
esac

# Smoke: RED (missing binary / failed canary) is error, not ok.
cat >"$tmp/smoke-red.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: RED"
echo "REASON: lastdbd binary not found/executable at /no/such/lastdbd"
exit 1
SH
chmod +x "$tmp/smoke-red.sh"
out="$(LASTDB_MINI_SMOKE_SH="$tmp/smoke-red.sh" LASTDB_MINI_SMOKE_BIN="$tmp/no-lastdbd" "$bin" lastdb-local-smoke-test 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=error' || fail "RED smoke must be error: $out"
printf '%s\n' "$out" | grep -q 'verdict=RED' || fail "RED smoke must keep verdict: $out"

cat >"$tmp/smoke-green.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: GREEN"
echo "SUMMARY: fixture green"
exit 0
SH
chmod +x "$tmp/smoke-green.sh"
out="$(LASTDB_MINI_SMOKE_SH="$tmp/smoke-green.sh" LASTDB_MINI_SMOKE_BIN="$tmp/no-lastdbd" "$bin" lastdb-local-smoke-test)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok detail=verdict=GREEN' || fail "GREEN smoke must be ok: $out"

echo "ok"
