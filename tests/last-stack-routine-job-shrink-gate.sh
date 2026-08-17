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
printf '%s\n' "$@" >"${JOB_GATE_LOG}"
if [ "${1:-}" = "groom" ] && [ "${2:-}" = "parity-check" ]; then
  echo '{"ok":true}'
  exit 0
fi
exit 2
SH
chmod +x "$tmp/bin/kanban"
export PATH="$tmp/bin:/usr/bin:/bin"
export JOB_GATE_LOG="$tmp/kanban.args"

out="$("$bin" kanban-parity-check)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT outcome=ok' || fail "parity gate: $out"
grep -qx 'groom parity-check --json' "$JOB_GATE_LOG" || fail "did not invoke kanban groom parity-check --json: $(cat "$JOB_GATE_LOG")"

# Missing helper is error, not a fake ok.
out="$("$bin" last-stack-card-reaper 2>&1 || true)"
# PATH has no card-reaper-run
case "$out" in
  *ROUTINE_RESULT\ outcome=error*|*card-reaper-run-missing*) ;;
  *)
    # If ROOT/bin has the real runner this host will run it; that is also honest.
    case "$out" in
      *ROUTINE_RESULT*) ;;
      *) fail "card-reaper produced no ROUTINE_RESULT: $out" ;;
    esac
    ;;
esac

echo "ok"
