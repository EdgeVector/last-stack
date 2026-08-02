#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-ledger-sync"
chmod +x "$BIN"
python3 "$BIN" --self-test
# driver mentions ledger-sync
grep -q 'last-stack-north-star-ledger-sync' "$ROOT/routines/north-star-driver.md"
grep -q 'Skip stale pending requests' "$ROOT/routines/north-star-driver.md"
echo "last-stack-north-star-ledger-sync tests ok"
