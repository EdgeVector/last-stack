#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"
inst="$ROOT/bin/last-stack-factory-health-install"
chmod +x "$bin" "$inst" 2>/dev/null || true
python3 -m py_compile "$bin"
"$bin" --help >/dev/null
# dry-run should not page
"$bin" --dry-run --no-notify --config "$ROOT/config/factory-health.toml" >/dev/null
echo "ok last-stack-factory-health"
