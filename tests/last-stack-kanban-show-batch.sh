#!/usr/bin/env bash
# The public raw23 reader is the sole route. Missing flat results refuse.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/public-card-reader.py"
