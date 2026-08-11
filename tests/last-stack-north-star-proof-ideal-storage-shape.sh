#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ideal-storage-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

evidence="$WORK/evidence.json"
cat >"$evidence" <<'JSON'
{
  "surface": {
    "kind": "cow",
    "primary_mutated": false,
    "dogfood_mini_verified": true,
    "captured_at": "2026-08-11T05:00:00Z"
  },
  "protein_plane": {
    "collection": "proteins",
    "prefixes": ["protein:", "molprot:", "fldprot:", "pfq:"],
    "create_member_write_fold": true,
    "legacy_tips_get": true,
    "copy_verify": "green",
    "legacy_hits": 0
  },
  "backup_manifest": {"mutable_includes": ["tips", "proteins"]},
  "design": {"revision": 3, "decisions": ["K16", "K17", "K18"]},
  "plane_map": {
    "one_tip_home": true,
    "single_indexes_home": true,
    "order_log_history_adjacent": true,
    "cold_ops_classified": true,
    "collapsed_plane_legacy_hits": 0
  },
  "status": {
    "proteins_present": true,
    "dual_read_legacy_hits_visible": true
  },
  "fkanban": {
    "protein_primary": true,
    "boardcards_milestonecards_agree": true,
    "dual_write_fallback": false,
    "atom_gc_tip_fold_verified": true
  },
  "refs": {"fold": "fold-test-ref", "fkanban": "fkanban-test-ref"}
}
JSON

"$RUNNER" --list | grep -qx 'north-star-lastdb-ideal-storage-shape'

LASTDB_IDEAL_STORAGE_SHAPE_PROOF_EVIDENCE_FILE="$evidence" \
NORTH_STAR_PROOF_DIR="$WORK/reports" \
  "$RUNNER" --offline north-star-lastdb-ideal-storage-shape >"$WORK/proof.out"

report="$WORK/reports/north-star-lastdb-ideal-storage-shape.md"
test "$(sed -n '1p' "$report")" = PASS
grep -q 'primary was not mutated' "$report"
grep -q 'BoardCards/MilestoneCards agreement' "$report"

"$EVALUATOR" --kind validation \
  --predicate "file $report matches /^PASS/" >"$WORK/evaluator.out"
grep -q '^satisfied:' "$WORK/evaluator.out"

bad="$WORK/bad-evidence.json"
sed 's/"primary_mutated": false/"primary_mutated": true/' "$evidence" >"$bad"
if LASTDB_IDEAL_STORAGE_SHAPE_PROOF_EVIDENCE_FILE="$bad" \
  NORTH_STAR_PROOF_DIR="$WORK/bad-reports" \
    "$RUNNER" --offline north-star-lastdb-ideal-storage-shape >"$WORK/bad.out" 2>&1; then
  echo "FAIL: primary-mutated evidence was accepted" >&2
  exit 1
fi
test "$(sed -n '1p' "$WORK/bad-reports/north-star-lastdb-ideal-storage-shape.md")" = FAIL

echo "PASS last-stack-north-star-proof-ideal-storage-shape"
