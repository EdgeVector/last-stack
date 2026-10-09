#!/usr/bin/env bash
# The exact GitHub label and current PR body govern lifecycle closure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/lifecycle-github.py"
