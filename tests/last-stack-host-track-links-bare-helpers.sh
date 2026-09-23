#!/usr/bin/env bash
# CI entry for tests/last-stack-host-track-links-bare-helpers.py (ci_test runs bash).
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd -P)/last-stack-host-track-links-bare-helpers.py"
