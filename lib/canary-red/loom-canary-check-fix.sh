#!/usr/bin/env bash
# Resume check for HEAL. 0 = landed (or stand-in / blocked with a result),
# 1 = not landed, else unknown.
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

status = str(ctx.get("heal_status") or "")
if status in ("fixed", "blocked", "noop", "stand-in"):
    sys.exit(0)
if str(ctx.get("merge_sha") or "").strip():
    sys.exit(0)
sys.exit(1)
PY
