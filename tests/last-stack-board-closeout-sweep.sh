#!/usr/bin/env bash
# Smoke-test board-closeout-sweep CLI shape (no live board required for --help).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-board-closeout-sweep"
install="$ROOT/bin/last-stack-board-closeout-install"
chmod +x "$bin" "$install" 2>/dev/null || true

bash -n "$bin"
bash -n "$install"

"$bin" --help >/dev/null
"$install" --help >/dev/null 2>&1 || true

# usage / dry-run should not crash when board is unavailable in CI
if command -v kanban >/dev/null 2>&1; then
  # dry-run is safe; may noop or list — exit 0 either way
  "$bin" --dry-run --max-actions 1 >/dev/null || true
fi

# A chained caller must survive this helper (no exec node/python3).
if grep -nE '^[[:space:]]*exec[[:space:]]+(node|python3)' "$bin"; then
  echo "FAIL: last-stack-board-closeout-sweep must not exec the engine" >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/board-closeout-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export BOARD_CLOSEOUT_STATE_DIR="$tmp/state"

# Piped empty-board noop must still emit JSON + heartbeat (heartbeat last).
empty_cli="$tmp/empty-board"
cat >"$empty_cli" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo '[]' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$empty_cli"
piped_out="$("$bin" --board-cli "$empty_cli" --skip-zombie --dry-run --max-actions 1)"
printf '%s\n' "$piped_out" | grep -q '"kind":"board-closeout"'
printf '%s\n' "$piped_out" | grep -qE '^board-closeout .+ noop closed=0'
last_line="$(printf '%s\n' "$piped_out" | tail -1)"
case "$last_line" in
  board-closeout\ *) ;;
  *)
    echo "FAIL: heartbeat must be last line, got: $last_line" >&2
    printf '%s\n' "$piped_out" >&2
    exit 1
    ;;
esac

# Silent engine still gets a fallback JSON + heartbeat line.
# Copy into a stack without prelude so PATH cannot be rewritten back to
# a real node (last-stack-shell-prelude prepends ~/.local/bin).
silent_stack="$tmp/silent-stack"
mkdir -p "$silent_stack/bin" "$tmp/silent-path"
cp "$bin" "$silent_stack/bin/last-stack-board-closeout-sweep"
chmod +x "$silent_stack/bin/last-stack-board-closeout-sweep"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$tmp/silent-path/node"
chmod +x "$tmp/silent-path/node"
silent_out="$(
  PATH="$tmp/silent-path:/usr/bin:/bin" \
    "$silent_stack/bin/last-stack-board-closeout-sweep" \
    --board-cli "$empty_cli" --dry-run
)"
printf '%s\n' "$silent_out" | grep -q '"kind":"board-closeout"'
printf '%s\n' "$silent_out" | grep -q 'flagged=engine-silent'
printf '%s\n' "$silent_out" | grep -q '^board-closeout '

echo "ok last-stack-board-closeout-sweep"
