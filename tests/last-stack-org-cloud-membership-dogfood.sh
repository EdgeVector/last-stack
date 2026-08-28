#!/usr/bin/env bash
# DEV/CI wrapper. The packed artifact runs the same fixture from harness/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec bash "$ROOT/harness/north-star/org-cloud-membership/offline-fixture.sh" "$@"
