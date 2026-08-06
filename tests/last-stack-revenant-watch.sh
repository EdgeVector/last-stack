#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLASSIFY="$ROOT/bin/last-stack-revenant-classify"
PROOF="$ROOT/harness/north-star/revenant-watch/run.sh"

chmod +x "$CLASSIFY" "$PROOF" 2>/dev/null || true

# Contract: skill lists the profile
rg -q 'profile=<[^>]*revenant-watch' "$ROOT/skills/session-miner/SKILL.md" \
  || rg -q 'revenant-watch' "$ROOT/skills/session-miner/SKILL.md"

# Classifier unit: flag
"$CLASSIFY" "$ROOT/harness/north-star/revenant-watch/fixtures/A-flag-removed-surface.json" \
  --expect flag >/dev/null

# Classifier unit: skip in-flight
"$CLASSIFY" "$ROOT/harness/north-star/revenant-watch/fixtures/B-skip-inflight.json" \
  --expect skip >/dev/null

# Classifier unit: no flag
"$CLASSIFY" "$ROOT/harness/north-star/revenant-watch/fixtures/C-no-flag-modern-plan.json" \
  --expect no_flag >/dev/null

# Full harness
"$PROOF" | tee /tmp/revenant-watch-proof.out
rg -q '^PASS fixture A' /tmp/revenant-watch-proof.out
rg -q '^PASS fixture B' /tmp/revenant-watch-proof.out
rg -q '^PASS fixture C' /tmp/revenant-watch-proof.out

echo "ok last-stack-revenant-watch"
