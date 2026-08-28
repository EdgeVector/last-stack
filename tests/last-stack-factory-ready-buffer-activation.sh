#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-ready-buffer-activation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

home="$TMP/home"
plist="$home/Library/LaunchAgents/com.edgevector.factory-ready-buffer.plist"
legacy_plist="$home/Library/LaunchAgents/com.edgevector.idle-ladder.plist"
legacy_script="$home/.routines/bin/last-stack-idle-ladder.sh"
mkdir -p "$(dirname "$plist")" "$(dirname "$legacy_script")"
printf '%s\n' legacy >"$legacy_plist"
printf '%s\n' legacy >"$legacy_script"

HOME="$home" \
LAST_STACK_PUBLIC_ROOT="$ROOT" \
LAST_STACK_LAUNCHD_DOMAIN=none \
FACTORY_READY_BUFFER_PLIST="$plist" \
FACTORY_READY_BUFFER_LEGACY_PLIST="$legacy_plist" \
FACTORY_READY_BUFFER_LEGACY_SCRIPT="$legacy_script" \
  "$ROOT/bin/last-stack-factory-ready-buffer-install" install >/dev/null

[ -f "$plist" ]
[ ! -e "$legacy_plist" ]
[ ! -e "$legacy_script" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$plist")" = 1800 ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" \
  = "$ROOT/bin/last-stack-factory-ready-buffer-controller" ]

status="$(
  HOME="$home" \
  LAST_STACK_PUBLIC_ROOT="$ROOT" \
  LAST_STACK_LAUNCHD_DOMAIN=none \
  FACTORY_READY_BUFFER_PLIST="$plist" \
  FACTORY_READY_BUFFER_LEGACY_PLIST="$legacy_plist" \
  FACTORY_READY_BUFFER_LEGACY_SCRIPT="$legacy_script" \
    "$ROOT/bin/last-stack-factory-ready-buffer-install" status
)"
grep -Fq 'interval_s: 1800' <<<"$status"
grep -Fq 'legacy_plist: absent' <<<"$status"
grep -Fq 'legacy_script: absent' <<<"$status"
jq -e '
  .apps[]
  | select(.app == "last-stack")
  | .links
  | any(
      .source == "bin/last-stack-factory-ready-buffer-install"
      and .target == "$HOME/.local/bin/last-stack-factory-ready-buffer-install"
    )
' "$ROOT/config/host-track/apps.json" >/dev/null

python3 - "$ROOT/bin/last-stack-factory-health" <<'PY'
import importlib.machinery
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_loader(
    "factory_health", importlib.machinery.SourceFileLoader("factory_health", path)
)
module = importlib.util.module_from_spec(spec)
sys.modules["factory_health"] = module
spec.loader.exec_module(module)

cfg = {
    "ready_buffer": {"enabled": True, "zero_alert_after_s": 3600},
    "ship_rate": {"enabled": False},
    "doing": {"enabled": False},
    "todo": {"enabled": False},
    "backlog": {"enabled": False},
    "ship_volume": {"enabled": False},
    "install": {"enabled": False},
    "closeout": {"enabled": False},
}
snap = module.Snapshot(ts="test", pickup_ready=0)
state = {}
meta = {
    "safe_milestone_frontier": True,
    "safe_milestone_frontier_detail": "factory-ready-buffer-control",
    "now_epoch": 1000,
}
assert module.evaluate(cfg, snap, meta, state) == []
meta["now_epoch"] = 4599
assert module.evaluate(cfg, snap, meta, state) == []
meta["now_epoch"] = 4600
alerts = module.evaluate(cfg, snap, meta, state)
assert [a.code for a in alerts] == ["ready_buffer_zero_sustained"]

snap.pickup_ready = 1
assert module.evaluate(cfg, snap, meta, state) == []
assert "ready_buffer_zero_since_epoch" not in state["streaks"]

snap.pickup_ready = 0
meta["safe_milestone_frontier"] = False
meta["now_epoch"] = 9000
assert module.evaluate(cfg, snap, meta, state) == []
assert "ready_buffer_zero_since_epoch" not in state["streaks"]
PY

bash "$ROOT/tests/last-stack-factory-ready-buffer-controller.sh"
echo "ok: factory ready-buffer activation"
