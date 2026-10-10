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
  details="The controller, installer, health command, and LaunchAgent source files are present. This source check does not prove live activation."
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

status_out="$("$installed_installer" status 2>&1)"
details="$(cat <<EOF
The live controller passed.

- Program: $program
- Interval: ${interval}s
- Legacy plist: absent
- Legacy script: absent
- Controller result: $controller_out

Installer status:

\`\`\`text
$status_out
\`\`\`
EOF
)"
ns_write_report "$SLUG" PASS "$details"
