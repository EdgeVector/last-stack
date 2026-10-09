#!/usr/bin/env bash
# last-stack-guard-loops-install installs ONLY the lastdb memory guard. The Forgejo
# runner watchdog (com.edgevector.forge-runner-watchdog) is no longer a label it can
# render, install or revive: no repo is gated on Forgejo any more (EdgeVector/lastgit
# moved to GitHub on 2026-10-08), so the watchdog would page about a Forgejo that is
# being shut down. A watchdog agent already loaded on a host is left alone.
# Fixture only: launchctl is a stub that fails the test if anything calls it, the
# plist dir, public root and HOME are temp dirs, and LAST_STACK_LAUNCHD_DOMAIN=none.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
INSTALL="$ROOT/bin/last-stack-guard-loops-install"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/guard-loops-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/home" "$tmp/stack/bin" "$tmp/stub" "$tmp/LaunchAgents" "$tmp/hb"
# The rendered argv must name files that exist before the installer accepts a plist.
# The memory guard plist names the public root; the watchdog plist names the artifact
# `current` tree under HOME. Both exist, so a re-added watchdog label WOULD render.
mkdir -p "$tmp/home/.local/state/last-stack/artifacts/current/bin"
for f in last-stack-launchd-loop last-stack-lastdb-memory-guard last-stack-forge-runner-watchdog; do
  printf '#!/bin/sh\nexit 0\n' >"$tmp/stack/bin/$f"; chmod +x "$tmp/stack/bin/$f"
  cp "$tmp/stack/bin/$f" "$tmp/home/.local/state/last-stack/artifacts/current/bin/$f"
done
cat >"$tmp/stub/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >>"${STUB_LAUNCHCTL_LOG:?}"
exit 0
SH
chmod +x "$tmp/stub/launchctl"
export STUB_LAUNCHCTL_LOG="$tmp/launchctl.log"; : >"$STUB_LAUNCHCTL_LOG"

# A watchdog plist an earlier install left behind must survive untouched.
printf 'legacy-watchdog\n' >"$tmp/LaunchAgents/com.edgevector.forge-runner-watchdog.plist"

run_install() {
  PATH="$tmp/stub:$PATH" HOME="$tmp/home" USER=fixture \
  LAST_STACK_PUBLIC_ROOT="$tmp/stack" LAST_STACK_LAUNCHD_DOMAIN=none \
  GUARD_LOOPS_PLIST_DIR="$tmp/LaunchAgents" LAUNCHD_LOOP_HEARTBEAT_DIR="$tmp/hb" \
    "$INSTALL" "$@"
}

out="$(run_install install 2>&1)" || fail "install failed: $out"
[ -f "$tmp/LaunchAgents/com.edgevector.lastdb-memory-guard.plist" ] \
  || fail "install did not write the lastdb memory guard plist: $out"
[ "$(cat "$tmp/LaunchAgents/com.edgevector.forge-runner-watchdog.plist")" = legacy-watchdog ] \
  || fail "install touched the watchdog plist"
printf '%s\n' "$out" | grep -qi 'watchdog' && fail "install mentions the watchdog: $out"
[ ! -s "$STUB_LAUNCHCTL_LOG" ] || fail "install called launchctl: $(cat "$STUB_LAUNCHCTL_LOG")"

# A fresh plist dir gets exactly one plist: the memory guard.
rm -rf "$tmp/LaunchAgents"; mkdir -p "$tmp/LaunchAgents"
run_install install >/dev/null 2>&1 || fail "second install failed"
count="$(find "$tmp/LaunchAgents" -maxdepth 1 -name '*.plist' | wc -l | tr -d ' ')"
[ "$count" = 1 ] || fail "expected exactly one installed plist, found $count"
[ ! -e "$tmp/LaunchAgents/com.edgevector.forge-runner-watchdog.plist" ] \
  || fail "install rendered the watchdog plist"

# The watchdog plist file stays packaged for a later cleanup (not removed wholesale).
[ -f "$ROOT/launchd/com.edgevector.forge-runner-watchdog.plist" ] \
  || fail "the packaged watchdog plist was removed; that belongs to a later cleanup"

run_install status >/dev/null 2>&1 || fail "status failed"
echo "ok last-stack-guard-loops-install"
