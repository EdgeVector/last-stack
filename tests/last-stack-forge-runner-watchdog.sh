#!/usr/bin/env bash
# Proof: the runner watchdog pages only on real outages, never revives a lane a
# human deliberately parked, and keeps --dry-run side-effect free.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
wd="$ROOT/bin/last-stack-forge-runner-watchdog"
chmod +x "$wd"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

plists="$tmp/LaunchAgents"; mkdir -p "$plists"
pages="$tmp/pages.log"; : >"$pages"
loaded="$tmp/loaded"                     # labels the fake launchd reports loaded
bootstrapped="$tmp/bootstrapped"; : >"$bootstrapped"

# --- stubs --------------------------------------------------------------------
cat >"$tmp/launchctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)      cat "$FAKE_LOADED" 2>/dev/null || true ;;
  enable)    : ;;
  bootstrap) printf '%s\n' "${3:-}" >> "$FAKE_BOOTSTRAPPED"
             # A bootstrap "succeeds": mark the label loaded for later probes.
             lbl="$(basename "${3:-}" .plist)"
             printf '99999\t0\t%s\n' "$lbl" >> "$FAKE_LOADED" ;;
esac
EOF

cat >"$tmp/ra" <<'EOF'
#!/usr/bin/env bash
# ra notify "<msg>" --priority <p>
shift  # drop "notify"
printf '%s\n' "$1" >> "$FAKE_PAGES"
EOF

cat >"$tmp/lanes" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_LANES_JSON"
EOF

cat >"$tmp/situations" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/launchctl" "$tmp/ra" "$tmp/lanes" "$tmp/situations"

lanes_healthy="$tmp/lanes-healthy.json"
cat >"$lanes_healthy" <<'EOF'
{"heavy_ok_live": true,
 "live": {"admin_runners": [{"name":"pc-forge-runner","status":"idle","labels":["pc-linux"]}]}}
EOF

lanes_pc_offline="$tmp/lanes-pc-offline.json"
cat >"$lanes_pc_offline" <<'EOF'
{"heavy_ok_live": true,
 "live": {"admin_runners": [{"name":"pc-forge-runner","status":"offline","labels":["pc-linux"]}]}}
EOF

run_wd() {  # state-dir, lanes-json, extra args...
  local sd="$1" lanes="$2"; shift 2
  FAKE_LOADED="$loaded" FAKE_BOOTSTRAPPED="$bootstrapped" \
  FAKE_PAGES="$pages" FAKE_LANES_JSON="$lanes" \
  FORGE_WATCHDOG_LAUNCHCTL="$tmp/launchctl" \
  FORGE_WATCHDOG_RA="$tmp/ra" \
  FORGE_WATCHDOG_LANES="$tmp/lanes" \
  FORGE_WATCHDOG_SITUATIONS="$tmp/situations" \
  FORGE_WATCHDOG_PLIST_DIR="$plists" \
  FORGE_WATCHDOG_STATE_DIR="$sd" \
  "$wd" "$@" >/dev/null 2>&1 || true
}

all_loaded() {
  : >"$loaded"
  for l in com.edgevector.forgejo-runner-host \
           com.edgevector.forgejo-runner-host-exemem-infra \
           com.edgevector.forgejo-runner; do
    printf '111\t0\t%s\n' "$l" >> "$loaded"
  done
}

# --- 1. healthy fleet: silent, and no state written ---------------------------
all_loaded
: >"$pages"
sd="$tmp/s1"
run_wd "$sd" "$lanes_healthy"
[ ! -s "$pages" ] || { echo "FAIL: paged on a healthy fleet"; cat "$pages"; exit 1; }
echo "ok: healthy fleet does not page"

# --- 2. --dry-run must not write paging state or revive -----------------------
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
touch "$plists/com.edgevector.forgejo-runner-host.plist"
sd="$tmp/s2"
run_wd "$sd" "$lanes_healthy" --dry-run
[ ! -s "$pages" ] || { echo "FAIL: --dry-run sent a page"; exit 1; }
[ ! -s "$bootstrapped" ] || { echo "FAIL: --dry-run bootstrapped an agent"; exit 1; }
if [ -f "$sd/state.json" ] && [ "$(/usr/bin/jq -r 'length' "$sd/state.json")" != "0" ]; then
  echo "FAIL: --dry-run mutated state.json"; cat "$sd/state.json"; exit 1
fi
echo "ok: --dry-run is side-effect free"

# --- 3. crashed lane (live plist, no pause marker): revive, do not page -------
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
for l in com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  printf '111\t0\t%s\n' "$l" >> "$loaded"
done
touch "$plists/com.edgevector.forgejo-runner-host.plist"
sd="$tmp/s3"
run_wd "$sd" "$lanes_healthy"
grep -q "forgejo-runner-host.plist" "$bootstrapped" \
  || { echo "FAIL: crashed lane was not revived"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: paged for a lane it successfully revived"; cat "$pages"; exit 1; }
echo "ok: crashed lane is revived without paging"

# --- 4. deliberately paused lane: never revive, never page --------------------
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
rm -f "$plists/com.edgevector.forgejo-runner-host.plist"
touch "$plists/com.edgevector.forgejo-runner-host.plist.paused-20260727T180132Z"
for l in com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  printf '111\t0\t%s\n' "$l" >> "$loaded"
done
sd="$tmp/s4"
run_wd "$sd" "$lanes_healthy"
[ ! -s "$bootstrapped" ] || { echo "FAIL: revived a deliberately paused lane"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: paged about a deliberately paused lane"; cat "$pages"; exit 1; }
echo "ok: a human's pause is respected, not undone"
rm -f "$plists"/*.paused-* 2>/dev/null || true

# --- 5. pc-linux offline: page, because fold merges freeze --------------------
all_loaded
: >"$pages"
sd="$tmp/s5"
run_wd "$sd" "$lanes_pc_offline"
grep -q "pc-linux" "$pages" || { echo "FAIL: no page for an offline pc-linux gate"; cat "$pages"; exit 1; }
echo "ok: offline pc-linux merge gate pages"

# --- 6. same outage again inside the cooldown: no second page -----------------
: >"$pages"
run_wd "$sd" "$lanes_pc_offline"
[ ! -s "$pages" ] || { echo "FAIL: re-paged inside the cooldown"; cat "$pages"; exit 1; }
echo "ok: re-page cooldown suppresses repeat pages"

# --- 7. recovery: one page when it comes back --------------------------------
: >"$pages"
run_wd "$sd" "$lanes_healthy"
grep -q "healthy again" "$pages" || { echo "FAIL: no recovery page"; cat "$pages"; exit 1; }
echo "ok: recovery is announced once"

echo "PASS last-stack-forge-runner-watchdog"
