---
name: product-feature-ns-reconcile
cadence: daily
description: Zero-LLM — reconcile product feature catalog against North Star completion; incomplete NS blacklists public readiness (not local dogfood).
---

You are the **product-feature-ns-reconcile** routine. This run is **zero-LLM intent**:
prefer the deterministic script; do not redesign features or flip catalog defaults.

## Setup
```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" brain || true
```

## Run (required)
```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
# Prefer installed bin; fall back to this checkout.
RECON="$last_stack/bin/last-stack-product-feature-ns-reconcile"
if [ ! -x "$RECON" ]; then
  RECON="$(command -v last-stack-product-feature-ns-reconcile || true)"
fi
if [ ! -x "$RECON" ]; then
  echo "ERROR=reconcile-script-missing"
  exit 0
fi

# Optional: point at a fold checkout catalog if present
if [ -z "${PRODUCT_FEATURE_CATALOG:-}" ]; then
  for c in \
    "$HOME/.fkanban/worktrees/fold-kanban-product-feature-gates-app-registry/folddb_profile/feature_catalog.toml" \
    /Users/REPLACE/code/edgevector/fold/folddb_profile/feature_catalog.toml
  do
    if [ -f "$c" ]; then export PRODUCT_FEATURE_CATALOG="$c"; break; fi
  done
fi

set +e
"$RECON" --stamp
rc=$?
set -e

# Heartbeat
echo "product-feature-ns-reconcile rc=$rc"
# rc 0 PASS, 1 violations (papercut stamped by script), 2 tool failure
exit 0
```

## Rules
- Do **not** set `default_enabled=true` or announce publicly from this routine.
- Do **not** clear Tom's local `features.toml` dogfood enables.
- Incomplete North Star ⇒ feature stays blacklisted from GA/public (script enforces).
- Design: brain `design-product-feature-gates`, SOP `sop-product-feature-gates`.
