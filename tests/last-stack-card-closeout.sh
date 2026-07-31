#!/usr/bin/env bash
# Smoke-test the closeout helper's CLI shape (no live board required for --help/usage).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout"
chmod +x "$bin" "$ROOT/bin/last-stack-attribution-trailers" 2>/dev/null || true

# usage exit
if "$bin" 2>/dev/null; then
  echo "expected usage failure" >&2
  exit 1
fi

# Prefer dry structural checks: script is bash -n clean
bash -n "$bin"

if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  board="$tmp/slow-board"
  cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    sleep 5
    printf '{"slug":"%s","column":"doing","body":""}\n' "$2"
    ;;
  add|move)
    exit 0
    ;;
  *)
    echo "unexpected fake board command: $*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$board"
  started="$(date +%s)"
  if LAST_STACK_CARD_CLOSEOUT_COMMAND_TIMEOUT_SEC=1 "$bin" slow-card --board-cli "$board" >/tmp/card-closeout-slow.$$ 2>&1; then
    cat /tmp/card-closeout-slow.$$ >&2
    rm -f /tmp/card-closeout-slow.$$
    echo "expected slow board read to fail" >&2
    exit 1
  fi
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -gt 4 ]; then
    cat /tmp/card-closeout-slow.$$ >&2
    rm -f /tmp/card-closeout-slow.$$
    echo "slow board read was not bounded: elapsed=${elapsed}s" >&2
    exit 1
  fi
  grep -q 'FAILED card-read-failed slug=slow-card' /tmp/card-closeout-slow.$$
  rm -f /tmp/card-closeout-slow.$$
fi

# If fkanban is available and board works, optional live smoke is skipped here
# (routines CI should not thrash Tom's board).
echo "ok last-stack-card-closeout"
