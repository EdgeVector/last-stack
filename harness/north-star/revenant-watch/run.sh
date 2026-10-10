#!/usr/bin/env bash
# north-star-slug: north-star-revenant-watch
# Product source check for north-star-revenant-watch.
# The no-tests policy retired the synthetic expected-verdict fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
CLASSIFY="${LAST_STACK_REVENANT_CLASSIFY:-$ROOT/bin/last-stack-revenant-classify}"
REPORT_DIR="${LAST_STACK_FEATURE_PROOFS:-$HOME/.last-stack/feature-proofs}"
SLUG=revenant-watch

if [ ! -x "$CLASSIFY" ]; then
  echo "FAIL missing classifier: $CLASSIFY" >&2
  exit 1
fi

# Profile + routine must exist in the product tree.
need_files=(
  "$ROOT/skills/session-miner/SKILL.md"
  "$ROOT/routines/revenant-watch.md"
  "$ROOT/config/routines-registry/last-stack-revenant-watch.toml"
  "$ROOT/bin/last-stack-revenant-classify"
)
for f in "${need_files[@]}"; do
  if [ ! -e "$f" ]; then
    echo "FAIL missing product file: $f" >&2
    exit 1
  fi
done

if ! rg -q '### `revenant-watch`' "$ROOT/skills/session-miner/SKILL.md"; then
  echo "FAIL session-miner skill missing embedded profile revenant-watch" >&2
  exit 1
fi
if ! rg -q 'profile=revenant-watch' "$ROOT/routines/revenant-watch.md"; then
  echo "FAIL routine does not invoke profile=revenant-watch" >&2
  exit 1
fi
if ! rg -qi 'Brain only|Brain-only|never.*kanban' "$ROOT/routines/revenant-watch.md"; then
  echo "FAIL routine must declare Brain-only outputs" >&2
  exit 1
fi

printf 'PASS-OFFLINE product files present (skill profile, routine, registry, classifier)\n'

mkdir -p "$REPORT_DIR"
report="$REPORT_DIR/${SLUG}.md"
{
  echo "PASS-OFFLINE"
  echo
  echo "# Revenant Watch product source check"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Classifier: $CLASSIFY"
  echo "Root: $ROOT"
  echo
  echo "- Product files and profile declarations are present."
  echo "- No classifier behavior or live mining result is claimed."
} >"$report"

echo "PASS-OFFLINE wrote $report"
exit 0
