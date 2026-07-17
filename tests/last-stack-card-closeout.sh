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

# If fkanban is available and board works, optional live smoke is skipped here
# (routines CI should not thrash Tom's board). Unit-level bash -n is enough.
echo "ok last-stack-card-closeout"
