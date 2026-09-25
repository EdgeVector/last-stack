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

lanes_healthy="$tmp/lanes-healthy.json"
cat >"$lanes_healthy" <<'EOF'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [{"name":"pc-forge-runner","status":"idle","labels":["pc-linux"]}]}}
EOF

lanes_pc_offline="$tmp/lanes-pc-offline.json"
cat >"$lanes_pc_offline" <<'EOF'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [{"name":"pc-forge-runner","status":"offline","labels":["pc-linux"]}]}}
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
  FORGE_WATCHDOG_PC_PAUSE_FILE="$pause_file" \
  FORGE_WATCHDOG_STATE_DIR="$sd" \
  FORGE_WATCHDOG_FORGE_LOG="${FAKE_FORGE_LOG:-$tmp/no-forge.log}" \
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
 "live": {"ok": true, "admin_runners": [{"name":"pc-forge-runner","status":"offline","labels":["pc-linux"]}]}}
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

# --- 16. an unreadable pause file is NOT a pause (incl. empty file) ----------
# Fail loud: a truncated or half-written file must never silence a merge gate.
# Empty pause file is a specific issue (papercut-forge-runner-watchdog-empty-pause-jq-20260923)
# where different jq versions might parse it inconsistently.
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
echo "ok: only an explicit intent=paused is a pause (including empty files)"

# --- 16b. empty pause file specifically under both BSD and GNU jq -----------
# Verify empty file doesn't read as pause on both jq variants.
: >"$pages"
printf '' > "$pause_file"
run_wd "$tmp/s16b" "$lanes_pc_down"
grep -q "pc-linux" "$pages" \
  || { echo "FAIL: empty pause file was treated as active pause"; exit 1; }
rm -f "$pause_file"
echo "ok: empty pause file is treated as no pause"

# --- 17. under a pause the drain is reported, not paged ----------------------
# `active` means the PC is still finishing a job it already accepted.
lanes_pc_active="$tmp/lanes-pc-active.json"
cat >"$lanes_pc_active" <<'EOF'
{"heavy_ok_live": false,
 "live": {"ok": true, "admin_runners": [{"name":"pc-forge-runner","status":"active","labels":["pc-linux"]}]}}
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

# --- 19. launchd blind, forge says live: no revive, no page ------------------
# A sandboxed caller's `launchctl list` can omit loaded runners. The forge's own
# inventory decides. papercut-forge-runner-watchdog-dry-run-misclassifies-live-runners-20260922
lanes_mac_live="$tmp/lanes-mac-live.json"
cat >"$lanes_mac_live" <<'EOF2'
{"heavy_ok_live": true,
 "live": {"ok": true, "admin_runners": [
   {"name":"pc-forge-runner","status":"idle","labels":["pc-linux"]},
   {"name":"mac-forge-runner","status":"active","labels":["macos-arm64"]},
   {"name":"mac-forge-runner-host","status":"idle","labels":["macos"]}],
  "repo_runners": {"EdgeVector/exemem-infra": [
   {"name":"mac-forge-runner-host-exemem-infra","status":"idle","labels":["macos","heavy"]}]}}}
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
# down" or "pc-linux not registered", and it must not be hidden by a PC pause.
# papercut-forge-runner-watchdog-treats-failed-live-read-as-empty-inventory-20260923
lanes_403="$tmp/lanes-403.json"
cat >"$lanes_403" <<'EOF3'
{"heavy_ok_live": false,
 "live": {"ok": false, "error": "HTTP Error 403: Forbidden (token does not have at least one of required scope(s): [read:admin])",
  "admin_runners": [], "repo_runners": {}}}
EOF3
all_loaded
: >"$pages"; : >"$bootstrapped"
rm -f "$pause_file"
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

# same failure under a PC pause: still loud (it is not a PC lane symptom)
pause_pc "2026-09-23T01:40:00Z"
: >"$pages"
run_wd "$tmp/s21b" "$lanes_403"
grep -q "inventory is unreadable" "$pages" \
  || { echo "FAIL: a PC pause hid an unreadable inventory"; cat "$pages"; exit 1; }
rm -f "$pause_file"
echo "ok: a PC pause never hides an unreadable inventory"

# --dry-run reproduces the papercut: WOULD PAGE names the inventory, not lanes
out="$(FAKE_LOADED="$loaded" FAKE_BOOTSTRAPPED="$bootstrapped" FAKE_PAGES="$pages" \
  FAKE_LANES_JSON="$lanes_403" FAKE_NOTICES="$notices" \
  FORGE_WATCHDOG_LAUNCHCTL="$tmp/launchctl" FORGE_WATCHDOG_RA="$tmp/ra" \
  FORGE_WATCHDOG_LANES="$tmp/lanes" FORGE_WATCHDOG_SITUATIONS="$tmp/situations" \
  FORGE_WATCHDOG_PLIST_DIR="$plists" FORGE_WATCHDOG_PC_PAUSE_FILE="$pause_file" \
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

# --- 24. scheduled pause with expired `until`: auto-resumes (no manual intervention)
# papercut-pc-runner-did-not-resume-after-scheduled-pause-20260923
# When a scheduled pause has an `until` time in the past, watchdog should treat
# it as expired and restore normal alerting (no page for "healthy again" when it
# was never actually recovered; just restore the state).
all_loaded
: >"$pages"; : >"$notices"
sd="$tmp/s24"
# Write a pause with until time in the past
past_time="2026-09-20T00:00:00Z"  # definitely in the past
printf '%s\n' "{\"intent\":\"paused\",\"since\":\"2026-09-20T00:00:00Z\",\"until\":\"$past_time\",\"reason\":\"gaming session\"}" > "$pause_file"
# PC is down and pause is expired: should page (pause is expired so doesn't suppress)
run_wd "$sd" "$lanes_pc_down"
grep -q "pc-linux" "$pages" \
  || { echo "FAIL: an expired scheduled pause suppressed a PC outage alert"; cat "$pages"; exit 1; }
# Pause notice should NOT be recorded (pause is expired, not active)
[ ! -f "$sd/pc-pause-notice" ] || grep -q "paused by the owner" "$sd/watchdog.log" \
  || { echo "FAIL: expired pause was recorded as active in the state"; exit 1; }
echo "ok: expired scheduled pause does not suppress alerts (auto-resume)"

# --- 25. scheduled pause still active: continues to suppress ----------------
# When until time is in the future, the pause is still active and suppresses alerts.
all_loaded
: >"$pages"; : >"$notices"
sd="$tmp/s25"
# Write a pause with until time in the future
future_time="2099-12-31T23:59:59Z"
printf '%s\n' "{\"intent\":\"paused\",\"since\":\"2026-09-25T00:00:00Z\",\"until\":\"$future_time\",\"reason\":\"gaming\"}" > "$pause_file"
run_wd "$sd" "$lanes_pc_down"
[ ! -s "$pages" ] || { echo "FAIL: active scheduled pause did not suppress PC lane alerts"; cat "$pages"; exit 1; }
grep -q "PC CI paused by the owner" "$notices" \
  || { echo "FAIL: active scheduled pause not recorded in Situations"; cat "$notices"; exit 1; }
echo "ok: active scheduled pause continues to suppress alerts"
rm -f "$pause_file"

echo "PASS last-stack-forge-runner-watchdog"
