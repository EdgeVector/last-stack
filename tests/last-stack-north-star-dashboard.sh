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
  },
  {
    "slug": "schema-shared-surface-native-resolver-capstone",
    "title": "CAPSTONE: shared-surface + native resolver E2E",
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
    "slug": "coderings-ns-terminal-verification",
    "title": "CodeRings terminal verification",
    "column": "done",
    "kind": "validation",
    "north_star": "north-star-coderings",
    "tags": [],
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
    "tags": ["north-star", "schema-service"],
    "body": "## End state\n\nShared surfaces work.\n\n## Terminal verification\n\n- **Card:** `schema-shared-surface-native-resolver-capstone`\n- **Shape:** pr runnable harness\n"
  },
  {
    "type": "project",
    "slug": "north-star-storage-metering-correctness",
    "title": "🌟 North Star — cloud storage metering stays correct forever",
    "status": "in_progress",
    "tags": ["north-star", "metering"],
    "body": "## End state\n\nMeters match reality.\n"
  },
  {
    "type": "project",
    "slug": "north-star-coderings",
    "title": "🌟 North Star — CodeRings",
    "status": "in_progress",
    "tags": ["north-star", "coderings"],
    "body": "## End state\n\nSnapshots work.\n\n## Terminal verification\n\n- **Card:** `coderings-ns-terminal-verification`\n"
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
assert schema["counts"]["todo"] == 2, schema
assert schema["counts"]["doing"] == 1, schema
assert schema["counts"]["done"] == 1, schema
assert schema["live"] == 3, schema
assert schema["total"] == 4, schema
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
! grep -q "review=" "$WORK/out.md"
grep -q "North Star dashboard" "$WORK/out.html"
grep -q "schema-resolver-pack-public-origin" "$WORK/out.html"
grep -q "Live pressure = backlog + todo + doing." "$WORK/out.html"
! grep -q ">review<" "$WORK/out.html"

# Per-command timeout should make a stuck `brain get` non-fatal during optional
# body enrichment instead of hanging the whole dashboard refresh.
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/brain" <<'EOF'
#!/usr/bin/env bash
sleep 2
EOF
chmod +x "$WORK/fakebin/brain"
PATH="$WORK/fakebin:$PATH" LAST_STACK_NORTH_STAR_DASHBOARD_CMD_TIMEOUT=0.1 "$BIN" \
  --cards-json "$WORK/cards.json" \
  --projects-json "$WORK/projects.json" \
  --fetch-bodies \
  --stdout none >"$WORK/timeout.out" 2>"$WORK/timeout.err"

# completion contract
"$BIN" \
  --cards-json "$WORK/cards.json" \
  --projects-json "$WORK/projects.json" \
  --completion-json "$WORK/completion.json" \
  --stdout completion >"$WORK/completion.md" 2>"$WORK/completion.err"

python3 - <<'PY' "$WORK/completion.json"
import json, sys
c = json.load(open(sys.argv[1]))
by = {r["north_star"]: r for r in c["north_stars"]}
schema = by["north-star-schema-shared-surface-native-resolver"]
assert schema["named_terminal_slug"] == "schema-shared-surface-native-resolver-capstone", schema
assert schema["terminal_state"] == "live", schema
assert "terminal_live" in schema["flags"], schema
meter = by["north-star-storage-metering-correctness"]
assert "terminal_missing" in meter["flags"] or meter["terminal_state"] == "missing", meter
assert meter["has_end_state_section"] is True
coder = by["north-star-coderings"]
assert "ns_completable" in coder["flags"], coder
assert coder["terminal_state"] == "done", coder
assert c["summary"]["needs_work"] is True
print("completion assertions ok")
PY

grep -q "North Star completion report" "$WORK/completion.md"
grep -q "COMPLETION_NEEDS_WORK=1" "$WORK/completion.err"

WRAP="$ROOT/bin/last-stack-north-star-completion-check"
if [ -x "$WRAP" ]; then
  bash -n "$WRAP"
fi

echo "PASS last-stack-north-star-dashboard"
