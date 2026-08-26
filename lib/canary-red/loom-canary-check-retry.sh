#!/usr/bin/env bash
# Resume check for RETRY. 0 = a retry already recorded, 1 = not started.
set -euo pipefail

python3 <<'PY'
import json, os, sys

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

if os.environ.get("LOOM_LIVE") != "1" and os.environ.get("LOOM_CANARY_RED_LIVE") != "1":
    sys.exit(int(os.environ.get("LOOM_CHECK_EXIT", "0")))

if str(ctx.get("retry_exec_id") or "").strip():
    sys.exit(0)
verdict = str(ctx.get("verdict") or "")
if verdict in ("green", "exhausted", "blocked", "idle") and ctx.get("retry_reason"):
    sys.exit(0)
sys.exit(1)
PY
