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
notices="$tmp/notices.log"; : >"$notices"     # situations notices the watchdog posted

# --- stubs --------------------------------------------------------------------
cat >"$tmp/launchctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)      cat "$FAKE_LOADED" 2>/dev/null || true
             # The watchdog's own agent is loaded in a real gui domain; a
             # blind (sandboxed) caller sees nothing at all.
             [ "${FAKE_LAUNCHD_BLIND:-0}" = "1" ] || printf '1\t0\tcom.edgevector.forge-runner-watchdog\n' ;;
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
# preflight stays permissive; notices are recorded so tests can count them.
if [ "${1:-}" = "notice" ]; then
  title=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --title) title="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  printf '%s\n' "$title" >> "$FAKE_NOTICES"
fi
exit 0
EOF
chmod +x "$tmp/launchctl" "$tmp/ra" "$tmp/lanes" "$tmp/situations"

lanes_offline_gate="$tmp/lanes-offline-gate.json"
cat >"$lanes_offline_gate" <<'EOF'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [{"name":"mac-forge-runner","status":"offline","labels":["macos-arm64"]}]}}
EOF

lanes_healthy="$tmp/lanes-healthy.json"
cat >"$lanes_healthy" <<'EOF'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [{"name":"mac-forge-runner","status":"idle","labels":["macos-arm64"]}]}}
EOF

# The LastGit forge.log check must read a fixture, not the host: after the
# 2026-09-25 LastGit launchd pause the real log went stale and every run of
# this test paged on the "healthy" fleet.
run_wd() {  # state-dir, lanes-json, extra args...
  local sd="$1" lanes="$2"; shift 2
  FAKE_LOADED="$loaded" FAKE_BOOTSTRAPPED="$bootstrapped" \
  FAKE_PAGES="$pages" FAKE_LANES_JSON="$lanes" FAKE_NOTICES="$notices" \
  FORGE_WATCHDOG_LAUNCHCTL="$tmp/launchctl" \
  FORGE_WATCHDOG_RA="$tmp/ra" \
  FORGE_WATCHDOG_LANES="$tmp/lanes" \
  FORGE_WATCHDOG_SITUATIONS="$tmp/situations" \
  FORGE_WATCHDOG_PLIST_DIR="$plists" \
  FORGE_WATCHDOG_STATE_DIR="$sd" \
  FORGE_WATCHDOG_FORGE_LOG="${FAKE_FORGE_LOG:-$tmp/no-forge.log}" \
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

# --- 5. Mac merge-gate runner down and not revivable: page --------------------
# No plist to bootstrap, so the revive fails and the outage is real.
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
for l in com.edgevector.forgejo-runner-host com.edgevector.forgejo-runner-host-exemem-infra; do
  printf '111\t0\t%s\n' "$l" >> "$loaded"
done
rm -f "$plists"/com.edgevector.forgejo-runner.plist
sd="$tmp/s5"
run_wd "$sd" "$lanes_offline_gate"
grep -q "Forge merge-gate runner is DOWN" "$pages" || { echo "FAIL: no page for a dead merge-gate runner"; cat "$pages"; exit 1; }
echo "ok: a dead, unrevivable merge-gate runner pages"

# --- 6. same outage again inside the cooldown: no second page -----------------
: >"$pages"
run_wd "$sd" "$lanes_offline_gate"
[ ! -s "$pages" ] || { echo "FAIL: re-paged inside the cooldown"; cat "$pages"; exit 1; }
echo "ok: re-page cooldown suppresses repeat pages"

# --- 7. recovery: one page when it comes back --------------------------------
all_loaded
: >"$pages"
run_wd "$sd" "$lanes_healthy"
grep -q "healthy again" "$pages" || { echo "FAIL: no recovery page"; cat "$pages"; exit 1; }
echo "ok: recovery is announced once"

# --- 11. a forge API failure pages -------------------------------------------
all_loaded
: >"$pages"
run_wd "$tmp/s11" "$tmp/does-not-exist.json"
grep -q "forge API\|Forgejo runner API" "$pages" \
  || { echo "FAIL: a forge API failure did not page"; cat "$pages"; exit 1; }
echo "ok: a forge API failure pages"

# --- 19. launchd blind, forge says live: no revive, no page ------------------
# A sandboxed caller's `launchctl list` can omit loaded runners. The forge's own
# inventory decides. papercut-forge-runner-watchdog-dry-run-misclassifies-live-runners-20260922
lanes_mac_live="$tmp/lanes-mac-live.json"
cat >"$lanes_mac_live" <<'EOF2'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [
   {"name":"mac-forge-runner","status":"active","labels":["macos-arm64"]},
   {"name":"mac-forge-runner-host","status":"idle","labels":["macos"]}],
  "repo_runners": {"EdgeVector/exemem-infra": [
   {"name":"mac-forge-runner-host-exemem-infra","status":"idle","labels":["macos"]}]}}}
EOF2
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
for l in com.edgevector.forgejo-runner-host com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  touch "$plists/$l.plist"
done
sd="$tmp/s19"
run_wd "$sd" "$lanes_mac_live"
[ ! -s "$bootstrapped" ] || { echo "FAIL: revived lanes the forge reports live"; cat "$bootstrapped"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: paged about lanes the forge reports live"; cat "$pages"; exit 1; }
grep -q "forge reports runner mac-forge-runner 'active'" "$sd/watchdog.log" \
  || { echo "FAIL: the launchd/forge disagreement was not recorded"; cat "$sd/watchdog.log"; exit 1; }
echo "ok: launchd-blind caller trusts the forge's live runner inventory"

# --- 20. launchd blind AND forge says offline: still revive ------------------
sed 's/"mac-forge-runner","status":"active"/"mac-forge-runner","status":"offline"/' "$lanes_mac_live" > "$tmp/lanes-mac-offline.json"
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
sd="$tmp/s20"
run_wd "$sd" "$tmp/lanes-mac-offline.json"
grep -q "com.edgevector.forgejo-runner.plist" "$bootstrapped" \
  || { echo "FAIL: an offline, unlisted merge-gate runner was not revived"; exit 1; }
echo "ok: an offline runner is still revived"
for l in com.edgevector.forgejo-runner-host com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  rm -f "$plists/$l.plist"
done

# --- 21. a FAILED live read is not an empty inventory -----------------------
# The lanes helper exits 0 when the forge answers 403; the failure is only in
# `.live.ok == false`. That must page "inventory unreadable", never "heavy lane
# down", never as a lane outage.
# papercut-forge-runner-watchdog-treats-failed-live-read-as-empty-inventory-20260923
lanes_403="$tmp/lanes-403.json"
cat >"$lanes_403" <<'EOF3'
{"heavy_ok_live": false,
 "live": {"ok": false, "error": "HTTP Error 403: Forbidden (token does not have at least one of required scope(s): [read:admin])",
  "admin_runners": [], "repo_runners": {}}}
EOF3
all_loaded
: >"$pages"; : >"$bootstrapped"
sd="$tmp/s21"
run_wd "$sd" "$lanes_403"
grep -q "inventory unreadable\|inventory is unreadable" "$pages" \
  || { echo "FAIL: a 403 live read did not page as inventory unreadable"; cat "$pages"; exit 1; }
grep -q "read:admin" "$pages" \
  || { echo "FAIL: the page does not carry the forge error text"; cat "$pages"; exit 1; }
if grep -q "No runner is LIVE\|NOT registered\|CI runner lane down" "$pages"; then
  echo "FAIL: a failed live read was reported as runners down"; cat "$pages"; exit 1
fi
[ ! -s "$bootstrapped" ] || { echo "FAIL: a failed live read revived lanes"; exit 1; }
[ "$(/usr/bin/jq -r 'has("forge-inventory-unreadable")' "$sd/state.json")" = "true" ] \
  || { echo "FAIL: inventory-unreadable state not recorded"; cat "$sd/state.json"; exit 1; }
echo "ok: a failed live read pages as inventory unreadable, not runners down"

# --dry-run reproduces the papercut: WOULD PAGE names the inventory, not lanes
out="$(FAKE_LOADED="$loaded" FAKE_BOOTSTRAPPED="$bootstrapped" FAKE_PAGES="$pages" \
  FAKE_LANES_JSON="$lanes_403" FAKE_NOTICES="$notices" \
  FORGE_WATCHDOG_LAUNCHCTL="$tmp/launchctl" FORGE_WATCHDOG_RA="$tmp/ra" \
  FORGE_WATCHDOG_LANES="$tmp/lanes" FORGE_WATCHDOG_SITUATIONS="$tmp/situations" \
  FORGE_WATCHDOG_PLIST_DIR="$plists" \
  FORGE_WATCHDOG_STATE_DIR="$tmp/s21c" FORGE_WATCHDOG_FORGE_LOG="$tmp/no-forge.log" "$wd" --dry-run 2>&1 || true)"
printf '%s\n' "$out" | grep -q "WOULD PAGE.*blind" \
  || { echo "FAIL: dry-run did not name a blind watchdog"; printf '%s\n' "$out"; exit 1; }
if printf '%s\n' "$out" | grep -q "No runner is LIVE\|NOT registered"; then
  echo "FAIL: dry-run still reports runners down on a 403"; printf '%s\n' "$out"; exit 1
fi
echo "ok: dry-run on a 403 reports a blind watchdog"

# --- 22. partial inventory keeps the launchd-blind fallback ------------------
# Admin read fails (403) but a repo-level runner is readable and idle. launchd
# does not list it: the forge's partial answer still wins, no revive.
lanes_partial="$tmp/lanes-partial.json"
cat >"$lanes_partial" <<'EOF4'
{"heavy_ok_live": false,
 "live": {"ok": false, "error": "HTTP Error 403: Forbidden",
  "admin_runners": [],
  "repo_runners": {"EdgeVector/fold": [
   {"name":"mac-forge-runner-host","status":"idle","labels":["macos"]}]}}}
EOF4
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
for l in com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  printf '111\t0\t%s\n' "$l" >> "$loaded"
done
touch "$plists/com.edgevector.forgejo-runner-host.plist"
sd="$tmp/s22"
run_wd "$sd" "$lanes_partial"
[ ! -s "$bootstrapped" ] || { echo "FAIL: revived a runner the partial inventory reports idle"; cat "$bootstrapped"; exit 1; }
grep -q "forge reports runner mac-forge-runner-host 'idle'" "$sd/watchdog.log" \
  || { echo "FAIL: partial inventory not used for the launchd-blind fallback"; cat "$sd/watchdog.log"; exit 1; }
rm -f "$plists/com.edgevector.forgejo-runner-host.plist"
echo "ok: a partial inventory still feeds the launchd-blind fallback"

# --- 23. blind launchd view + incomplete inventory: no revive, no page ------
# 2026-09-23T05:58Z: a sandboxed shell saw no agents, the forge answered 403,
# and the watchdog paged all three Mac lanes DOWN. Neither source had evidence.
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
for l in com.edgevector.forgejo-runner-host com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  touch "$plists/$l.plist"
done
sd="$tmp/s23"
FAKE_LAUNCHD_BLIND=1 run_wd "$sd" "$lanes_403"
[ ! -s "$bootstrapped" ] || { echo "FAIL: a blind shell revived lanes"; cat "$bootstrapped"; exit 1; }
if grep -q "is DOWN" "$pages"; then
  echo "FAIL: a blind shell with a 403 inventory paged lanes DOWN"; cat "$pages"; exit 1
fi
grep -q "launchd view blind" "$sd/watchdog.log" \
  || { echo "FAIL: blind launchd view not logged"; cat "$sd/watchdog.log"; exit 1; }
echo "ok: a blind shell with an incomplete inventory does not page lanes down"

# blind launchd view but a COMPLETE inventory that says offline: still acts
: >"$bootstrapped"; : >"$pages"
FAKE_LAUNCHD_BLIND=1 run_wd "$tmp/s23b" "$tmp/lanes-mac-offline.json"
grep -q "com.edgevector.forgejo-runner.plist" "$bootstrapped" \
  || { echo "FAIL: complete inventory saying offline was ignored in a blind shell"; exit 1; }
for l in com.edgevector.forgejo-runner-host com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  rm -f "$plists/$l.plist"
done
echo "ok: a complete inventory still drives revive in a blind shell"

echo "PASS last-stack-forge-runner-watchdog"
