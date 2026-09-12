#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
python3 "$ROOT/tests/last-stack-pipeline-pr-guard.py"
