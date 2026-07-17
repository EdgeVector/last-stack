#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-proof"
chmod +x "$BIN" "$ROOT/harness/north-star"/*/run.sh

"$BIN" --list | grep -q north-star-coderings
"$BIN" --list | grep -q north-star-schema-shared-surface-native-resolver

PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ns-proof-test.XXXXXX")"
trap 'rm -rf "$PROOF_DIR"' EXIT
export NORTH_STAR_PROOF_DIR="$PROOF_DIR"
export NORTH_STAR_PROOF_MODE=offline
export EDGEVECTOR_WORKSPACE="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}"

# Always-safe offline proofs when checkouts exist
if [ -d "$EDGEVECTOR_WORKSPACE/coderings" ]; then
  "$BIN" --offline north-star-coderings
  head -1 "$PROOF_DIR/north-star-coderings.md" | grep -qE '^PASS'
fi

if command -v lastdb >/dev/null 2>&1; then
  "$BIN" --offline north-star-app-ops-latency
  head -1 "$PROOF_DIR/north-star-app-ops-latency.md" | grep -qE '^PASS'
fi

# Structural: all harness scripts exist and bash -n clean
for s in coderings deliver-slices lastgit metering minimal-node app-ops schema; do
  bash -n "$ROOT/harness/north-star/$s/run.sh"
done
bash -n "$BIN"
bash -n "$ROOT/harness/north-star/common.sh"

echo "PASS last-stack-north-star-proof"
