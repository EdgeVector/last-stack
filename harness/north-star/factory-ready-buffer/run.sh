#!/usr/bin/env bash
# north-star-slug: north-star-factory-ready-buffer
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG="north-star-factory-ready-buffer"
MODE="$(ns_mode)"
LIVE_ROOT="${LAST_STACK_LIVE_ROOT:-$HOME/.last-stack}"
details=""

fail() {
  ns_write_report "$SLUG" FAIL "$1" || true
  exit 1
}

for path in \
  "$ROOT/bin/last-stack-factory-ready-buffer-controller" \
  "$ROOT/bin/last-stack-factory-ready-buffer-install" \
  "$ROOT/bin/last-stack-factory-health" \
  "$ROOT/launchd/com.edgevector.factory-ready-buffer.plist"; do
  [ -e "$path" ] || fail "Missing shipped path: $path"
done

if [ "$MODE" = "offline" ]; then
  proof_out="$(bash "$ROOT/tests/last-stack-factory-ready-buffer-activation.sh" 2>&1)" \
    || fail "$(printf 'Offline activation proof failed.\n\n%s' "$proof_out")"
  details="$(printf 'Offline activation checks passed.\n\n%s' "$proof_out")"
  ns_write_report "$SLUG" PASS-OFFLINE "$details"
  exit 0
fi

installed_controller="$LIVE_ROOT/bin/last-stack-factory-ready-buffer-controller"
installed_installer="$LIVE_ROOT/bin/last-stack-factory-ready-buffer-install"
installed_health="$LIVE_ROOT/bin/last-stack-factory-health"
live_plist="$HOME/Library/LaunchAgents/com.edgevector.factory-ready-buffer.plist"
legacy_plist="$HOME/Library/LaunchAgents/com.edgevector.idle-ladder.plist"
legacy_script="$HOME/.routines/bin/last-stack-idle-ladder.sh"

[ -x "$installed_controller" ] || fail "The installed controller is missing: $installed_controller"
[ -x "$installed_installer" ] || fail "The installed installer is missing: $installed_installer"
[ -x "$installed_health" ] || fail "The installed health check is missing: $installed_health"
[ -f "$live_plist" ] || fail "The live LaunchAgent file is missing: $live_plist"

program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$live_plist" 2>/dev/null || true)"
interval="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$live_plist" 2>/dev/null || true)"
[ "$program" = "$installed_controller" ] \
  || fail "The live LaunchAgent uses the wrong program: ${program:-missing}"
[ "$interval" = 1800 ] || fail "The live LaunchAgent interval is ${interval:-missing}, not 1800."

uid="$(id -u)"
launch_out="$(launchctl print "gui/${uid}/com.edgevector.factory-ready-buffer" 2>&1)" \
  || fail "The factory ready-buffer LaunchAgent is not loaded.\n\n$launch_out"
[ ! -e "$legacy_plist" ] || fail "The legacy idle-ladder plist still exists."
[ ! -e "$legacy_script" ] || fail "The legacy idle-ladder script still exists."
if launchctl print "gui/${uid}/com.edgevector.idle-ladder" >/dev/null 2>&1; then
  fail "The legacy idle-ladder LaunchAgent is still loaded."
fi

controller_out="$("$installed_controller" --dry-run --json 2>&1)" \
  || fail "The live controller could not read the pickup state.\n\n$controller_out"
printf '%s\n' "$controller_out" | jq -e '
  .result == "ok"
  and (.ready | type == "number")
  and (.action == "none" or .action == "would-run")
' >/dev/null || fail "The live controller result is invalid.\n\n$controller_out"

health_out="$(python3 - "$installed_health" <<'PY'
import importlib.machinery
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_loader(
    "live_factory_health", importlib.machinery.SourceFileLoader("live_factory_health", path)
)
module = importlib.util.module_from_spec(spec)
sys.modules["live_factory_health"] = module
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
snap = module.Snapshot(ts="proof", pickup_ready=0)
state = {}
meta = {
    "safe_milestone_frontier": True,
    "safe_milestone_frontier_detail": "proof-frontier",
    "now_epoch": 1000,
}
assert module.evaluate(cfg, snap, meta, state) == []
meta["now_epoch"] = 4600
alerts = module.evaluate(cfg, snap, meta, state)
assert [a.code for a in alerts] == ["ready_buffer_zero_sustained"]
print("ready-buffer-starvation-alert: PASS")
PY
)" || fail "The starvation alert proof failed.\n\n$health_out"

status_out="$("$installed_installer" status 2>&1)"
details="$(cat <<EOF
The live controller passed.

- Program: $program
- Interval: ${interval}s
- Legacy plist: absent
- Legacy script: absent
- Controller result: $controller_out
- Health proof: $health_out

Installer status:

\`\`\`text
$status_out
\`\`\`
EOF
)"
ns_write_report "$SLUG" PASS "$details"
