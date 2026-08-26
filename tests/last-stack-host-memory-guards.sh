#!/usr/bin/env bash
# Host-side memory guard fixtures.
#
# These jobs can kill processes, so the properties under test are mostly
# about when they do NOT fire, plus dry-run on a fake comm path. A real
# kill of Tom's lastdbd is forbidden here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUI="$ROOT/bin/last-stack-gui-app-memory-guard"
TESTBIN="$ROOT/bin/last-stack-testbin-memory-guard"
SENTINEL="$ROOT/bin/last-stack-host-memory-sentinel"
INSTALL="$ROOT/bin/last-stack-host-memory-guards-install"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/host-memory-guards.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/home/.lastdb/monitoring" "$tmp/home/.last-stack/bin" \
  "$tmp/home/.last-stack/launchd" "$tmp/home/.last-stack/lib" \
  "$tmp/home/Library/LaunchAgents" "$tmp/jetsam"
export HOME="$tmp/home"
export USER="testuser"

# --- shims -----------------------------------------------------------------
cat >"$tmp/bin/ps" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "-Ao pid=,comm=") printf '%s %s\n' "${FAKE_PID:-4242}" "${FAKE_COMM:-/tmp/FakeApp}" ;;
  *"-o rss="*)      printf '%s\n' "${FAKE_RSS_KB:-0}" ;;
  *)                exit 1 ;;
esac
SH

cat >"$tmp/bin/top" <<'SH'
#!/usr/bin/env bash
printf 'PID MEM\n%s %s\n' "${FAKE_PID:-4242}" "${FAKE_TOP_MEM:-10M}"
SH

cat >"$tmp/bin/kill" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -0) exit 1 ;;
esac
printf 'kill %s\n' "$*" >>"${FAKE_ACTION_LOG:?}"
SH

cat >"$tmp/bin/sysctl" <<'SH'
#!/usr/bin/env bash
printf 'total = 8192.00M  used = %s.00M  free = 100.00M\n' "${FAKE_SWAP_MB:-10}"
SH

cat >"$tmp/bin/memory_pressure" <<'SH'
#!/usr/bin/env bash
printf 'the system has %s%% free memory\nfree percentage: %s%%\n' \
  "${FAKE_FREE_PCT:-40}" "${FAKE_FREE_PCT:-40}"
SH

cat >"$tmp/bin/ra" <<'SH'
#!/usr/bin/env bash
printf 'ra %s\n' "$*" >>"${FAKE_ACTION_LOG:?}"
SH

cat >"$tmp/bin/situations" <<'SH'
#!/usr/bin/env bash
printf 'situations %s\n' "$*" >>"${FAKE_ACTION_LOG:?}"
SH

cat >"$tmp/bin/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"${LAUNCHCTL_LOG:?}"
exit 0
SH

chmod +x "$tmp/bin/"*
export FAKE_ACTION_LOG="$tmp/actions.log"
export LAUNCHCTL_LOG="$tmp/launchctl.log"
: >"$FAKE_ACTION_LOG"
: >"$LAUNCHCTL_LOG"

pin_path() {
  export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export GUI_GUARD_PATH="$PATH"
  export TESTBIN_GUARD_PATH="$PATH"
  export SENTINEL_PATH="$PATH"
}

reset_actions() { : >"$FAKE_ACTION_LOG"; rm -f "$HOME/.lastdb/monitoring/"*.log; }
killed() { grep -q '^kill ' "$FAKE_ACTION_LOG" 2>/dev/null; }

pin_path

# --- 1. GUI default allowlist does not match a fake comm path ----------------
reset_actions
FAKE_COMM="/tmp/FakeActivityMonitor" \
FAKE_RSS_KB=$((9000 * 1024)) \
FAKE_TOP_MEM=9G \
GUI_GUARD_DRY_RUN=1 \
  "$GUI" >/dev/null 2>&1 || fail "gui guard should exit 0 on a non-allowlisted comm"
killed && fail "gui default allowlist must not kill a fake comm path"
grep -q 'DRY_RUN would kill' "$HOME/.lastdb/monitoring/gui-app-memory-guard.log" \
  && fail "gui default allowlist must not dry-run-kill a fake comm"
grep -q 'ok watched=0' "$HOME/.lastdb/monitoring/gui-app-memory-guard.log" \
  || fail "gui default allowlist should watch nothing for a fake comm"

# --- 2. GUI dry-run on an allowlisted fake comm does not call kill -----------
reset_actions
FAKE_COMM="/tmp/FakeApp" \
FAKE_RSS_KB=$((9000 * 1024)) \
FAKE_TOP_MEM=9G \
GUI_GUARD_ALLOWLIST="/tmp/FakeApp" \
GUI_GUARD_DRY_RUN=1 \
  "$GUI" >/dev/null 2>&1 || fail "gui dry-run should exit 0"
killed && fail "gui DRY_RUN must not call kill"
grep -q 'DRY_RUN would kill' "$HOME/.lastdb/monitoring/gui-app-memory-guard.log" \
  || fail "gui DRY_RUN should log the would-kill line"

# --- 3. GUI over-limit allowlisted fake comm logs OVER_LIMIT, never lastdbd --
# `kill` is a bash builtin, so PATH shims do not intercept it. A fake pid is
# not a live process; the builtin no-ops behind `2>/dev/null || true`.
reset_actions
FAKE_COMM="/tmp/FakeApp" \
FAKE_RSS_KB=$((9000 * 1024)) \
FAKE_TOP_MEM=9G \
GUI_GUARD_ALLOWLIST="/tmp/FakeApp" \
  "$GUI" >/dev/null 2>&1 || fail "gui kill path should exit 0"
grep -q 'OVER_LIMIT killing pid=4242' "$HOME/.lastdb/monitoring/gui-app-memory-guard.log" \
  || fail "gui over-limit allowlisted fake comm must log OVER_LIMIT"
grep -q 'lastdbd' "$HOME/.lastdb/monitoring/gui-app-memory-guard.log" \
  && fail "gui over-limit log mentioned lastdbd"

# --- 4. GUI never kills lastdbd even if the allowlist names it ---------------
reset_actions
FAKE_COMM="/opt/lastdb/bin/lastdbd" \
FAKE_RSS_KB=$((20000 * 1024)) \
FAKE_TOP_MEM=20G \
GUI_GUARD_ALLOWLIST="/opt/lastdb/bin/lastdbd" \
  "$GUI" >/dev/null 2>&1 || fail "gui lastdbd skip should exit 0"
killed && fail "gui must never kill lastdbd"

# --- 5. testbin dry-run on a cargo deps comm ---------------------------------
reset_actions
FAKE_COMM="/tmp/project-zeus-photo-target.QCWXoV/debug/deps/fold_db-deadbeef" \
FAKE_RSS_KB=$((9000 * 1024)) \
FAKE_TOP_MEM=9G \
TESTBIN_GUARD_DRY_RUN=1 \
  "$TESTBIN" >/dev/null 2>&1 || fail "testbin dry-run should exit 0"
killed && fail "testbin DRY_RUN must not call kill"
grep -q 'DRY_RUN would kill' "$HOME/.lastdb/monitoring/testbin-memory-guard.log" \
  || fail "testbin DRY_RUN should log the would-kill line"

# --- 6. testbin does not match lastdbd ---------------------------------------
reset_actions
FAKE_COMM="/opt/lastdb/bin/lastdbd" \
FAKE_RSS_KB=$((20000 * 1024)) \
FAKE_TOP_MEM=20G \
  "$TESTBIN" >/dev/null 2>&1 || fail "testbin lastdbd skip should exit 0"
killed && fail "testbin must never kill lastdbd"
grep -q 'ok watched=0' "$HOME/.lastdb/monitoring/testbin-memory-guard.log" \
  || fail "testbin should watch nothing for lastdbd"

# --- 7. testbin under the limit does not kill --------------------------------
reset_actions
FAKE_COMM="/tmp/fold/target/debug/deps/fold_db-abc" \
FAKE_RSS_KB=$((100 * 1024)) \
FAKE_TOP_MEM=100M \
  "$TESTBIN" >/dev/null 2>&1 || fail "testbin under-limit should exit 0"
killed && fail "testbin must not kill under the 8 GiB limit"

# --- 8. sentinel dry-run alerts without paging --------------------------------
reset_actions
FAKE_SWAP_MB=30000 \
FAKE_FREE_PCT=40 \
SENTINEL_DRY_RUN=1 \
SENTINEL_COOLDOWN_SEC=0 \
SENTINEL_JETSAM_DIR="$tmp/jetsam" \
SENTINEL_RA="$tmp/bin/ra" \
SENTINEL_SITUATIONS="$tmp/bin/situations" \
  "$SENTINEL" >/dev/null 2>&1 || fail "sentinel dry-run should exit 0"
grep -q '^ra ' "$FAKE_ACTION_LOG" && fail "sentinel DRY_RUN must not call ra"
grep -q '^situations ' "$FAKE_ACTION_LOG" && fail "sentinel DRY_RUN must not call situations"
grep -q 'ALERT key=swap' "$HOME/.lastdb/monitoring/host-memory-sentinel.log" \
  || fail "sentinel should log a swap alert in dry-run"
grep -q 'DRY_RUN: page + notice skipped' "$HOME/.lastdb/monitoring/host-memory-sentinel.log" \
  || fail "sentinel dry-run should skip the page"

# --- 9. sentinel never contains a kill invocation ----------------------------
if grep -E 'kill -(TERM|KILL|9)|launchctl (bootout|kickstart)' "$SENTINEL" >/dev/null; then
  fail "sentinel script must not kill or kickstart anything"
fi
if grep -E 'kill -(TERM|KILL)|launchctl kickstart' \
     "$ROOT/bin/last-stack-host-memory-guards-install" >/dev/null; then
  fail "host-memory installer must not kill or kickstart a process"
fi

# --- 10. installer writes three stable-root plists; never launchctl lastdbd --
cp "$ROOT/lib/last-stack-launchd-agent.sh" "$HOME/.last-stack/lib/"
for bin in last-stack-gui-app-memory-guard last-stack-testbin-memory-guard \
           last-stack-host-memory-sentinel last-stack-host-memory-guards-install; do
  cp "$ROOT/bin/$bin" "$HOME/.last-stack/bin/"
  chmod +x "$HOME/.last-stack/bin/$bin"
done
for plist in com.edgevector.gui-app-memory-guard.plist \
             com.edgevector.testbin-memory-guard.plist \
             com.edgevector.host-memory-sentinel.plist; do
  cp "$ROOT/launchd/$plist" "$HOME/.last-stack/launchd/"
done
# Leftover machine-local labels must be retired. A live lastdbd plist must stay.
printf 'legacy\n' >"$HOME/Library/LaunchAgents/com.example.gui-app-memory-guard.plist"
printf 'keep-lastdb\n' >"$HOME/Library/LaunchAgents/com.edgevector.lastdb-memory-guard.plist"
: >"$LAUNCHCTL_LOG"
export LAST_STACK_LAUNCHD_DOMAIN=none
export LAST_STACK_PUBLIC_ROOT="$HOME/.last-stack"
out="$("$INSTALL" install)" || fail "installer failed: $out"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "expected launchctl skipped, got: $out"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "installer called launchctl under DOMAIN=none: $(cat "$LAUNCHCTL_LOG")"
[ ! -f "$HOME/Library/LaunchAgents/com.example.gui-app-memory-guard.plist" ] \
  || fail "installer left a leftover per-user gui-app plist"
[ "$(cat "$HOME/Library/LaunchAgents/com.edgevector.lastdb-memory-guard.plist")" = keep-lastdb ] \
  || fail "installer mutated the lastdbd memory-guard plist"

for label in com.edgevector.gui-app-memory-guard \
             com.edgevector.testbin-memory-guard \
             com.edgevector.host-memory-sentinel; do
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  [ -f "$plist" ] || fail "missing $plist"
  prog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist")"
  case "$prog" in
    "$HOME/.last-stack/bin/"last-stack-*) ;;
    *) fail "$label program=$prog" ;;
  esac
  case "$prog" in
    */artifacts/versions/*) fail "$label still version-pinned: $prog" ;;
  esac
  grep -q lastdbd "$plist" && fail "$label plist mentions lastdbd"
done

# Reinstall is a no-op.
out="$("$INSTALL" install)" || fail "second install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "expected already current, got: $out"

printf 'PASS: last-stack-host-memory-guards\n'
