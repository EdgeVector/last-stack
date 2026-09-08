#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"
inst="$ROOT/bin/last-stack-factory-health-install"
chmod +x "$bin" "$inst" 2>/dev/null || true
python3 -m py_compile "$bin"
"$bin" --help >/dev/null
# Exercise the real CLI against isolated inputs; a dry run still reads the
# board, so the production config made this test depend on primary latency.
python3 "$ROOT/tests/factory-health-dry-run.py"
echo "ok last-stack-factory-health"
