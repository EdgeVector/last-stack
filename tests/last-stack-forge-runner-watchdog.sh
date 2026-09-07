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
pause_file="$tmp/pc-pause.json"               # durable owner PC pause, factory-owned

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
  FAKE_PAGES="$pages" FAKE_LANES_JSON="$lanes" FAKE_NOTICES="$notices" \
  FORGE_WATCHDOG_LAUNCHCTL="$tmp/launchctl" \
  FORGE_WATCHDOG_RA="$tmp/ra" \
  FORGE_WATCHDOG_LANES="$tmp/lanes" \
  FORGE_WATCHDOG_SITUATIONS="$tmp/situations" \
  FORGE_WATCHDOG_PLIST_DIR="$plists" \
  FORGE_WATCHDOG_PC_PAUSE_FILE="$pause_file" \
  FORGE_WATCHDOG_STATE_DIR="$sd" \
  "$wd" "$@" >/dev/null 2>&1 || true
}

pause_pc()  { printf '%s\n' "{\"intent\":\"paused\",\"since\":\"$1\",\"reason\":\"owner is gaming\"}" > "$pause_file"; }
resume_pc() { printf '%s\n' '{"intent":"normal"}' > "$pause_file"; }

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

# --- 8. owner PC pause: PC lanes go quiet, nothing else does ------------------
# Both PC lanes are down at once: `heavy` (pc-heavy-runner) and `pc-linux`
# (pc-forge-runner). Under an owner pause neither is news.
lanes_pc_down="$tmp/lanes-pc-down.json"
cat >"$lanes_pc_down" <<'EOF'
{"heavy_ok_live": false,
 "live": {"admin_runners": [{"name":"pc-forge-runner","status":"offline","labels":["pc-linux"]}]}}
EOF

all_loaded
: >"$pages"; : >"$notices"
pause_pc 2026-09-07T07:00:00Z
sd="$tmp/s8"
run_wd "$sd" "$lanes_pc_down"
[ ! -s "$pages" ] || { echo "FAIL: an owner PC pause still paged"; cat "$pages"; exit 1; }
grep -q "PC CI paused by the owner" "$notices" \
  || { echo "FAIL: the pause was not recorded in Situations"; cat "$notices"; exit 1; }
echo "ok: an owner PC pause silences the PC lanes and is recorded once"

# --- 9. the same pause, run again: no second notice, still no page ------------
: >"$pages"; : >"$notices"
run_wd "$sd" "$lanes_pc_down"
[ ! -s "$pages" ] || { echo "FAIL: paged on the second run of the same pause"; exit 1; }
[ ! -s "$notices" ] || { echo "FAIL: re-announced a pause already recorded"; cat "$notices"; exit 1; }
echo "ok: a held pause is announced once, not once per run"

# --- 10. a pause hides the PC lanes only -------------------------------------
# A Mac lane that cannot be revived must still page while the PC is paused.
: >"$loaded"; : >"$bootstrapped"; : >"$pages"
rm -f "$plists"/com.edgevector.forgejo-runner-host.plist
for l in com.edgevector.forgejo-runner-host-exemem-infra com.edgevector.forgejo-runner; do
  printf '111\t0\t%s\n' "$l" >> "$loaded"
done
run_wd "$tmp/s10" "$lanes_pc_down" --no-revive
grep -q "Forge heavy runner is DOWN" "$pages" \
  || { echo "FAIL: a PC pause hid a Mac runner outage"; cat "$pages"; exit 1; }
# The ℹ️ pause note is expected on an unrelated page; a PC lane ALERT is not.
grep -q "^• .*pc-linux runner is" "$pages" \
  && { echo "FAIL: alerted about the paused PC lane"; cat "$pages"; exit 1; }
grep -q "^• .*'heavy' label" "$pages" \
  && { echo "FAIL: alerted about the paused heavy lane"; cat "$pages"; exit 1; }
echo "ok: a PC pause never hides a Mac runner outage"

# --- 11. a pause does not hide a forge API failure ---------------------------
all_loaded
: >"$pages"
run_wd "$tmp/s11" "$tmp/does-not-exist.json"
grep -q "forge API\|Forgejo runner API" "$pages" \
  || { echo "FAIL: a PC pause hid a forge API failure"; cat "$pages"; exit 1; }
echo "ok: a PC pause never hides a forge API failure"

# --- 12. a pause freezes prior PC state; it is not a recovery -----------------
# PC goes down and pages first, THEN the owner pauses. The pause must not
# report "healthy again" for a lane nobody is watching, and must not drop the
# re-page cooldown that the real outage already earned.
all_loaded
: >"$pages"; : >"$notices"
resume_pc
sd="$tmp/s12"
run_wd "$sd" "$lanes_pc_down"
grep -q "pc-linux" "$pages" || { echo "FAIL: no page for a real PC outage"; cat "$pages"; exit 1; }
before="$(/usr/bin/jq -S -c '.' "$sd/state.json")"

: >"$pages"
pause_pc 2026-09-07T08:00:00Z
run_wd "$sd" "$lanes_pc_down"
grep -q "healthy again" "$pages" && { echo "FAIL: a pause faked a recovery"; cat "$pages"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: paged during a pause"; cat "$pages"; exit 1; }
[ "$(/usr/bin/jq -S -c '.' "$sd/state.json")" = "$before" ] \
  || { echo "FAIL: the pause mutated frozen PC lane state"; /usr/bin/jq -S . "$sd/state.json"; exit 1; }
echo "ok: a pause freezes prior PC lane state instead of faking a recovery"

# --- 13. the freeze survives a watchdog restart ------------------------------
: >"$pages"
run_wd "$sd" "$lanes_pc_down"
[ "$(/usr/bin/jq -S -c '.' "$sd/state.json")" = "$before" ] \
  || { echo "FAIL: a restart under pause lost the frozen state"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: a restart under pause paged"; cat "$pages"; exit 1; }
echo "ok: the pause and its frozen state survive a watchdog restart"

# --- 14. resume restores the state the pause froze ---------------------------
# The outage is over. Exactly one recovery page, from the state held since #12.
: >"$pages"; : >"$notices"
resume_pc
run_wd "$sd" "$lanes_healthy"
grep -q "healthy again" "$pages" || { echo "FAIL: resume lost the pending recovery"; cat "$pages"; exit 1; }
grep -q "PC CI resumed" "$notices" || { echo "FAIL: the resume was not recorded"; cat "$notices"; exit 1; }
: >"$pages"
run_wd "$sd" "$lanes_healthy"
[ ! -s "$pages" ] || { echo "FAIL: recovery was announced twice after resume"; cat "$pages"; exit 1; }
echo "ok: resume restores the frozen state and announces recovery once"

# --- 15. resume with the PC still down pages again ---------------------------
: >"$pages"
run_wd "$tmp/s15" "$lanes_pc_down"
grep -q "pc-linux" "$pages" || { echo "FAIL: resume did not restore PC alerting"; cat "$pages"; exit 1; }
echo "ok: after resume a still-down PC lane pages again"

# --- 16. an unreadable pause file is NOT a pause -----------------------------
# Fail loud: a truncated or half-written file must never silence a merge gate.
for bad in '' 'not json' '{"intent":' '{"intent":"pause"}' '{"paused":true}'; do
  : >"$pages"
  printf '%s' "$bad" > "$pause_file"
  run_wd "$tmp/s16-$RANDOM" "$lanes_pc_down"
  grep -q "pc-linux" "$pages" \
    || { echo "FAIL: pause file '$bad' silenced a real PC outage"; exit 1; }
done
rm -f "$pause_file"
: >"$pages"
run_wd "$tmp/s16-absent" "$lanes_pc_down"
grep -q "pc-linux" "$pages" || { echo "FAIL: a missing pause file silenced a PC outage"; exit 1; }
echo "ok: only an explicit intent=paused is a pause"

# --- 17. under a pause the drain is reported, not paged ----------------------
# `active` means the PC is still finishing a job it already accepted.
lanes_pc_active="$tmp/lanes-pc-active.json"
cat >"$lanes_pc_active" <<'EOF'
{"heavy_ok_live": false,
 "live": {"admin_runners": [{"name":"pc-forge-runner","status":"active","labels":["pc-linux"]}]}}
EOF
all_loaded
: >"$pages"
pause_pc 2026-09-07T09:00:00Z
sd="$tmp/s17"
run_wd "$sd" "$lanes_pc_active"
[ ! -s "$pages" ] || { echo "FAIL: paged about a draining PC lane"; cat "$pages"; exit 1; }
grep -q "still finishing an accepted job" "$sd/watchdog.log" \
  || { echo "FAIL: the drain of an active PC job was not reported"; cat "$sd/watchdog.log"; exit 1; }
: >"$pages"
run_wd "$sd" "$lanes_pc_down"
grep -q "has drained" "$sd/watchdog.log" \
  || { echo "FAIL: PC-drained was not reported"; cat "$sd/watchdog.log"; exit 1; }
echo "ok: a pause reports the PC drain instead of paging about it"

# --- 18. --dry-run stays side-effect free under a pause ----------------------
: >"$pages"; : >"$notices"
sd="$tmp/s18"
pause_pc 2026-09-07T10:00:00Z
run_wd "$sd" "$lanes_pc_down" --dry-run
[ ! -s "$notices" ] || { echo "FAIL: --dry-run posted a Situations notice"; cat "$notices"; exit 1; }
[ ! -f "$sd/pc-pause-notice" ] || { echo "FAIL: --dry-run wrote the pause notice marker"; exit 1; }
[ ! -s "$pages" ] || { echo "FAIL: --dry-run paged"; exit 1; }
echo "ok: --dry-run observes a pause without recording it"
rm -f "$pause_file"

echo "PASS last-stack-forge-runner-watchdog"
