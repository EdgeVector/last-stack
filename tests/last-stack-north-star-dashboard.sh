#!/usr/bin/env bash
# Unit test for last-stack-north-star-dashboard using fixtures (no live node).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-dashboard"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-dashboard-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

chmod +x "$BIN"

cat >"$WORK/cards.json" <<'EOF'
[
  {
    "slug": "schema-resolver-pack-public-origin",
    "title": "Public HTTPS origin for packs",
    "column": "todo",
    "kind": "pr",
    "north_star": "north-star-schema-shared-surface-native-resolver",
    "tags": ["p1"],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": ""
  },
  {
    "slug": "legacy-alias-card",
    "title": "Uses legacy schema NS slug",
    "column": "doing",
    "kind": "pr",
    "north_star": "lastdb-secrets-and-local-schema-resolver-roadmap-2026-07-06",
    "tags": ["p0"],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": ""
  },
  {
    "slug": "metering-wire-b2",
    "title": "Wire B2 events",
    "column": "todo",
    "kind": "pr",
    "north_star": "north-star-storage-metering-correctness",
    "tags": ["p1"],
    "blocked": true,
    "block_status": "none",
    "blockedBy": ["metering-land-infra-330"],
    "pr_url": ""
  },
  {
    "slug": "orphan-ns-card",
    "title": "Points at missing NS",
    "column": "backlog",
    "kind": "pr",
    "north_star": "north-star-does-not-exist",
    "tags": [],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": ""
  },
  {
    "slug": "done-under-ns",
    "title": "Already landed",
    "column": "done",
    "kind": "pr",
    "north_star": "north-star-schema-shared-surface-native-resolver",
    "tags": [],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": "https://example.invalid/1"
  },
  {
    "slug": "no-ns-live",
    "title": "Unattributed live",
    "column": "todo",
    "kind": "pr",
    "north_star": "",
    "tags": ["p2"],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": ""
  },
  {
    "slug": "sentry-triage-restore-signal-sources",
    "title": "sentry-triage: restore SENTRY_AUTH_TOKEN",
    "column": "todo",
    "kind": "pr",
    "north_star": "north-star-storage-metering-correctness",
    "tags": ["p2"],
    "blocked": false,
    "block_status": "none",
    "blockedBy": [],
    "pr_url": ""
  }
]
EOF

cat >"$WORK/projects.json" <<'EOF'
[
  {
    "type": "project",
    "slug": "north-star-schema-shared-surface-native-resolver",
    "title": "🌟 North Star — shared surfaces + native local schema resolver",
    "status": "in_progress",
    "tags": ["north-star", "schema-service"]
  },
  {
    "type": "project",
    "slug": "north-star-storage-metering-correctness",
    "title": "🌟 North Star — cloud storage metering stays correct forever",
    "status": "in_progress",
    "tags": ["north-star", "metering"]
  },
  {
    "type": "project",
    "slug": "active-programs",
    "title": "Active programs",
    "status": "planning",
    "tags": ["active-programs"]
  }
]
EOF

"$BIN" \
  --cards-json "$WORK/cards.json" \
  --projects-json "$WORK/projects.json" \
  --markdown "$WORK/out.md" \
  --html "$WORK/out.html" \
  --json-out "$WORK/out.json" \
  --hygiene-json "$WORK/hygiene.json" \
  --stdout none

# Alias folded into schema NS live count (todo + doing = 2 live + 1 done)
python3 - <<'PY' "$WORK/out.json" "$WORK/hygiene.json"
import json, sys
m = json.load(open(sys.argv[1]))
h = json.load(open(sys.argv[2]))
by = {s["slug"]: s for s in m["sections"]}
schema = by["north-star-schema-shared-surface-native-resolver"]
assert schema["counts"]["todo"] == 1, schema
assert schema["counts"]["doing"] == 1, schema
assert schema["counts"]["done"] == 1, schema
assert schema["live"] == 2, schema
assert schema["total"] == 3, schema
meter = by["north-star-storage-metering-correctness"]
assert meter["live"] == 2, meter  # metering-wire + intentional sentry mistag fixture
assert any(c["slug"] == "metering-wire-b2" for c in meter["blocked_cards"])
orphan = by["north-star-does-not-exist"]
assert orphan["status"] == "orphan"
assert orphan["live"] == 1, orphan
assert m["unattributed"]["total"] == 1
assert m["unattributed"]["live"][0]["slug"] == "no-ns-live"
# active_programs is NOT a north star
assert "active-programs" not in by
# hygiene report
assert h["summary"]["needs_work"] is True
assert h["summary"]["orphan_live_count"] >= 1
assert any(e["slug"] == "north-star-does-not-exist" for e in h["orphan_north_stars_live"])
# sentry under metering → mistag heuristic
assert any(e["slug"] == "sentry-triage-restore-signal-sources" for e in h["mistag_candidates"]), h["mistag_candidates"]
print("assertions ok")
PY

# hygiene stdout mode
"$BIN" \
  --cards-json "$WORK/cards.json" \
  --projects-json "$WORK/projects.json" \
  --stdout hygiene >"$WORK/hygiene.md" 2>"$WORK/hygiene.err"
grep -q "Orphan North Stars" "$WORK/hygiene.md"
grep -q "HYGIENE_NEEDS_WORK=1" "$WORK/hygiene.err"

grep -q "north-star-schema-shared-surface-native-resolver" "$WORK/out.md"
grep -q "Unattributed cards" "$WORK/out.md"
grep -q "North Star dashboard" "$WORK/out.html"
grep -q "schema-resolver-pack-public-origin" "$WORK/out.html"

echo "PASS last-stack-north-star-dashboard"
