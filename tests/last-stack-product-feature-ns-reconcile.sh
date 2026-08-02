#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/product-feature-ns"
set +e
out="$("$ROOT/bin/last-stack-product-feature-ns-reconcile" \
  --json \
  --catalog "$FIX/feature_catalog.toml" \
  --completion-json "$FIX/completion.json" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "expected rc=1 got $rc" >&2
  echo "$out" >&2
  exit 1
fi
echo "$out" | grep -q public_while_incomplete
echo "$out" | grep -q app_registry
echo "OK product-feature-ns-reconcile fixture"
