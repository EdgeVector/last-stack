#!/usr/bin/env bash
# LIST node: pull EV OPS coverage.exceptions ("What's wrong") into context.items.
# Effects: none. Override snapshot with WHATS_WRONG_SNAPSHOT_FILE or
# WHATS_WRONG_SNAPSHOT_URL (default http://127.0.0.1:7733/api/snapshot).
set -euo pipefail

python3 <<'PY'
import json, os, sys, urllib.request

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

dashboard = (
    ctx.get("dashboard")
    or os.environ.get("WHATS_WRONG_DASHBOARD")
    or os.environ.get("OPS_TERMINAL_URL")
    or "http://127.0.0.1:7733"
)
dashboard = str(dashboard).rstrip("/")
max_items = ctx.get("max_items")
if max_items is None:
    max_items = os.environ.get("WHATS_WRONG_MAX_ITEMS", "8")
try:
    max_items = int(max_items)
except (TypeError, ValueError):
    max_items = 8
if max_items < 0:
    max_items = 8

snap_file = os.environ.get("WHATS_WRONG_SNAPSHOT_FILE") or ""
url = os.environ.get("WHATS_WRONG_SNAPSHOT_URL") or (dashboard + "/api/snapshot")

def load_snapshot():
    if snap_file:
        with open(snap_file, encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=45) as resp:
        return json.loads(resp.read().decode("utf-8"))

try:
    snap = load_snapshot()
except Exception as e:
    print(f"whats-wrong-list: snapshot failed: {e}", file=sys.stderr)
    sys.exit(1)

coverage = snap.get("coverage") or {}
exceptions = coverage.get("exceptions") or []
if not isinstance(exceptions, list):
    exceptions = []

def rank(row):
    if not isinstance(row, dict):
        return (9, "")
    glyphs = [row.get("L"), row.get("F"), row.get("T")]
    bad = sum(1 for g in glyphs if g == "x")
    warn = sum(1 for g in glyphs if g == "o")
    # worse first, then stable id
    return (-bad, -warn, str(row.get("id") or ""))

clean = [r for r in exceptions if isinstance(r, dict) and r.get("id")]
clean.sort(key=rank)
capped = len(clean) > max_items
items = clean[:max_items]

patch = {
    "dashboard": dashboard,
    "items": items,
    "count": len(items),
    "available": len(clean),
    "capped": capped,
    "snapshot_url": url if not snap_file else snap_file,
}
print("LOOM_CONTEXT_PATCH:" + json.dumps(patch, separators=(",", ":")))
print(f"whats-wrong-list count={len(items)} available={len(clean)} capped={int(capped)}")
print("PASS")
PY
