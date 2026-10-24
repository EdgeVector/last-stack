#!/usr/bin/env bash
# Resume check for CUTOVER / PROMOTE. 0 = landed (or stand-in), 1 = not.
# Must not branch on LOOM_LIVE — the graph check is the same binary either way.
set -euo pipefail

native_input="${LOOM_INPUT:-}"
[ -n "$native_input" ] || native_input='{}'
if printf '%s' "$native_input" | jq -e \
  '.upgrade_mode == "native-v2-ci" or .item.upgrade_mode == "native-v2-ci"' >/dev/null; then
  exec python3 "$(dirname -- "$0")/native_v2_upgrade.py" CHECK
fi
if printf '%s' "$native_input" | jq -e \
  '.upgrade_mode == "native-logical-migration-cloud-off" or .item.upgrade_mode == "native-logical-migration-cloud-off"' >/dev/null; then
  exec python3 "$(dirname -- "$0")/native_migration.py" CHECK
fi
if printf '%s' "$native_input" | jq -e \
  '.upgrade_mode == "native-inplace-cloud-off" or .item.upgrade_mode == "native-inplace-cloud-off"' >/dev/null; then
  exec python3 "$(dirname -- "$0")/native_upgrade.py" CHECK
fi

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
