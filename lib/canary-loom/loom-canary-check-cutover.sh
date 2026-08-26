#!/usr/bin/env bash
# Resume check for CUTOVER / PROMOTE. 0 = landed (or stand-in), 1 = not.
# Must not branch on LOOM_LIVE — the graph check is the same binary either way.
set -euo pipefail

python3 <<'PY'
import json, os, sys

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

if str(ctx.get("cutover") or "") or str(ctx.get("promote") or ""):
    sys.exit(0)
sys.exit(int(os.environ.get("LOOM_CHECK_EXIT", "1")))
PY
