#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-board-drain-report"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-drain-report.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

chmod +x "$BIN"

cat >"$WORK/cards.json" <<'EOF'
[
  {"slug":"a","column":"backlog"},
  {"slug":"b","column":"todo"},
  {"slug":"c","column":"todo"},
  {"slug":"d","column":"doing"},
  {"slug":"e","column":"review"},
  {"slug":"f","column":"done"}
]
EOF

cat >"$WORK/heartbeats.txt" <<'EOF'
kanban-pickup 2026-07-16T09:50:00Z ok cards=1 worked=card-a result=merged pr=lastgit://last-stack/cr/cr-1 final_column=done
kanban-pickup 2026-07-16T09:30:00Z ok cards=1 worked=card-b result=review-blocked pr=lastgit://last-stack/cr/cr-2 reason=ci-missing
kanban-pickup 2026-07-16T08:45:00Z noop busy-node attempts=3
kanban-pickup 2026-07-16T07:00:00Z ok cards=1 worked=card-c,card-d result=merged pr=http://example.invalid/1
kanban-pickup 2026-07-15T11:00:00Z ok cards=1 worked=old-card result=merged pr=http://example.invalid/old
kanban-watch 2026-07-16T09:55:00Z ok moved-done=ignored
EOF

mkdir -p "$WORK/runs/last-stack-fkanban-pickup-w2/2026-07-16T09-40-00-000Z"
cat >"$WORK/runs/last-stack-fkanban-pickup-w2/2026-07-16T09-40-00-000Z/meta.json" <<'EOF'
{
  "id": "last-stack-fkanban-pickup-w2",
  "startedAt": "2026-07-16T09:40:00.000Z",
  "outcome": "ok",
  "outcomeDetail": "cards=1 worked=card-a result=merged"
}
EOF

mkdir -p "$WORK/runs/last-stack-fkanban-pickup/2026-07-16T08-30-00-000Z"
cat >"$WORK/runs/last-stack-fkanban-pickup/2026-07-16T08-30-00-000Z/meta.json" <<'EOF'
{
  "id": "last-stack-fkanban-pickup",
  "startedAt": "2026-07-16T08:30:00.000Z",
  "outcome": "noop",
  "outcomeDetail": "busy-node attempts=3"
}
EOF

"$BIN" \
  --cards-json "$WORK/cards.json" \
  --heartbeats-file "$WORK/heartbeats.txt" \
  --runs-dir "$WORK/runs" \
  --now 2026-07-16T10:00:00Z \
  --json >"$WORK/report.json"

python3 - <<'PY' "$WORK/report.json"
import json, sys

report = json.load(open(sys.argv[1]))
assert report["position"] == {
    "backlog": 1,
    "todo": 2,
    "doing": 1,
    "review": 1,
    "done": 1,
}, report["position"]
by_hours = {w["hours"]: w for w in report["velocity"]}
one = by_hours[1]
assert one["heartbeat_wakes"] == 2, one
assert one["run_meta_wakes"] == 1, one
assert one["claim_runs"] == 2, one
assert one["meta_claim_runs"] == 1, one
assert one["unique_cards"] == 2, one
assert one["merged"] == 1, one
assert one["review_blocked"] == 1, one
assert one["claim_rate_per_hour"] == 2.0, one
assert one["merge_rate_per_hour"] == 1.0, one
six = by_hours[6]
assert six["heartbeat_wakes"] == 4, six
assert six["claim_runs"] == 3, six
assert six["unique_cards"] == 4, six
assert six["merged"] == 2, six
assert six["noop_reasons"] == {"busy-node": 1}, six
assert six["run_meta_wakes"] == 2, six
assert six["meta_claim_runs"] == 1, six
print("assertions ok")
PY

"$BIN" \
  --cards-json "$WORK/cards.json" \
  --heartbeats-file "$WORK/heartbeats.txt" \
  --runs-dir "$WORK/runs" \
  --now 2026-07-16T10:00:00Z >"$WORK/report.txt"

grep -q "Position: backlog=1 todo=2 doing=1 review=1 done=1" "$WORK/report.txt"
grep -q "1h: wakes=2 run_meta=1 claim_runs=2" "$WORK/report.txt"
grep -q "noop_reasons=busy-node:1" "$WORK/report.txt"

echo "PASS last-stack-board-drain-report"
