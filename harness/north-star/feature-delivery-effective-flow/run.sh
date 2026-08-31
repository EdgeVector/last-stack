#!/usr/bin/env bash
# north-star-slug: north-star-feature-delivery-effective-flow
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MODE="${NORTH_STAR_PROOF_MODE:-offline}"
case "$MODE" in
  live) exec "$ROOT/bin/last-stack-feature-delivery-effective-flow-proof" --live ;;
  offline) exec "$ROOT/bin/last-stack-feature-delivery-effective-flow-proof" --offline ;;
  *) echo "FAIL: unsupported proof mode: $MODE" >&2; exit 2 ;;
esac
