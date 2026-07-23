#!/usr/bin/env bash
# Unit test for last-stack-milestone-factory-dashboard using fixtures (no live node).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-milestone-factory-dashboard"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/cards.json" <<'EOF'
[
  {"slug":"pr-a","title":"PR A","column":"todo","kind":"pr","milestone":"ms-a","north_star":"north-star-a"},
  {"slug":"pr-b","title":"PR B","column":"backlog","kind":"pr","milestone":"","north_star":""},
  {"slug":"val-a","title":"Proof","column":"backlog","kind":"validation","milestone":"ms-a","north_star":"north-star-a"}
]
EOF
cat >"$TMP/milestones.json" <<'EOF'
[
  {"slug":"ms-a","title":"Outcome A","state":"active","north_star":"north-star-a","proof_status":"pending","proof_card":"val-a","driver":"last-stack-milestone-driver"}
]
EOF
cat >"$TMP/projects.json" <<'EOF'
[
  {"slug":"north-star-a","title":"North Star A","status":"in_progress","tags":["north-star"]}
]
EOF

HTML="$TMP/out.html"
JSON="$TMP/out.json"
"$BIN" --cards-json "$TMP/cards.json" --milestones-json "$TMP/milestones.json" \
  --projects-json "$TMP/projects.json" --html "$HTML" --json-out "$JSON" >/tmp/mfd-out.txt

grep -q 'Milestone factory dashboard' "$HTML"
grep -q 'docs/ev-house.css' "$HTML"
grep -q 'Outcome A' "$HTML"
grep -q 'pr-a' "$HTML"
grep -q 'pr-b' "$HTML"
grep -q 'north-star-a' "$HTML"
python3 - <<PY
import json
m=json.load(open("$JSON"))
assert m["milestone_count"]==1
assert len(m["north_star_groups"])==1
assert m["north_star_groups"][0]["slug"]=="north-star-a"
assert len(m["unassigned"]["live_pr"])==1
assert m["unassigned"]["live_pr"][0]["slug"]=="pr-b"
print("ok model")
PY

echo "PASS last-stack-milestone-factory-dashboard"
