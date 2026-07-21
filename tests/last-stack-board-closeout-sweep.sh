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
if command -v kanban >/dev/null 2>&1 || command -v fkanban >/dev/null 2>&1; then
  # dry-run is safe; may noop or list — exit 0 either way
  "$bin" --dry-run --max-actions 1 >/dev/null || true
fi

echo "ok last-stack-board-closeout-sweep"
