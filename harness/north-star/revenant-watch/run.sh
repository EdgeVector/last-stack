#!/usr/bin/env bash
# Terminal proof for north-star-revenant-watch / milestone revenant-watch-daily-survey.
# Three fixtures:
#   A — removed surface claim → flag
#   B — same claim with open work → skip
#   C — modern plan → no_flag
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
CLASSIFY="${LAST_STACK_REVENANT_CLASSIFY:-$ROOT/bin/last-stack-revenant-classify}"
FIXDIR="$(cd "$(dirname "$0")/fixtures" && pwd -P)"
REPORT_DIR="${LAST_STACK_FEATURE_PROOFS:-$HOME/.last-stack/feature-proofs}"
SLUG=revenant-watch

if [ ! -x "$CLASSIFY" ]; then
  echo "FAIL missing classifier: $CLASSIFY" >&2
  exit 1
fi

# Profile + routine must exist in the product tree (install path proof).
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

pass_lines=()

run_fixture() {
  local label="$1"
  local file="$2"
  local expect="$3"
  local out rc
  set +e
  out="$("$CLASSIFY" "$file" --expect "$expect" --verbose 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL fixture $label expected verdict=$expect" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | rg -q "\"verdict\": \"$expect\""; then
    echo "FAIL fixture $label: classifier output missing verdict=$expect" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  pass_lines+=("PASS fixture $label → $expect")
  printf 'PASS fixture %s → %s\n' "$label" "$expect"
}

run_fixture A "$FIXDIR/A-flag-removed-surface.json" flag
run_fixture B "$FIXDIR/B-skip-inflight.json" skip
run_fixture C "$FIXDIR/C-no-flag-modern-plan.json" no_flag

printf 'PASS product files present (skill profile, routine, registry, classifier)\n'
pass_lines+=("PASS product files present (skill profile, routine, registry, classifier)")

mkdir -p "$REPORT_DIR"
report="$REPORT_DIR/${SLUG}.md"
{
  echo "PASS"
  echo
  echo "# Revenant Watch terminal proof"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Classifier: $CLASSIFY"
  echo "Root: $ROOT"
  echo
  for line in "${pass_lines[@]}"; do
    echo "- $line"
  done
} >"$report"

echo "PASS wrote $report"
exit 0
