#!/usr/bin/env bash
# Installers must write a stable public path, never artifacts/versions/<sha>,
# must skip launchctl when the plist is unchanged, and must refuse the real
# gui domain when the dest plist is not under the uid's real home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

home="$tmp/home"
install_root="$home/.local/state/last-stack/artifacts"
version="$install_root/versions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
compat="$home/.last-stack"
export HOME="$home"
export USER="testuser"
export LAST_STACK_LAUNCHD_DOMAIN=none
unset LAST_STACK_PUBLIC_ROOT

mkdir -p \
  "$version/bin" \
  "$version/lib" \
  "$version/launchd" \
  "$version/config" \
  "$compat" \
  "$home/Library/LaunchAgents"

ln -s "versions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "$install_root/current"
ln -s "$install_root/current/bin" "$compat/bin"
ln -s "$install_root/current/config" "$compat/config"
ln -s "$install_root/current/launchd" "$compat/launchd"

cp "$ROOT/bin/last-stack-factory-health-install" "$version/bin/"
cp "$ROOT/bin/last-stack-board-closeout-install" "$version/bin/"
cp "$ROOT/bin/last-stack-self-upgrade-install" "$version/bin/"
cp "$ROOT/bin/last-stack-admin-deliver-install" "$version/bin/"
cp "$ROOT/bin/last-stack-factory-ready-buffer-install" "$version/bin/"
cp "$ROOT/bin/last-stack-loom-reaper-install" "$version/bin/"
cp "$ROOT/lib/last-stack-launchd-agent.sh" "$version/lib/"
cp "$ROOT/launchd/com.edgevector.factory-health.plist" "$version/launchd/"
cp "$ROOT/launchd/com.edgevector.board-closeout.plist" "$version/launchd/"
cp "$ROOT/launchd/com.edgevector.last-stack-self-upgrade.plist" "$version/launchd/"
cp "$ROOT/bin/last-stack-vm-disk-trim-install" "$version/bin/"
cp "$ROOT/launchd/com.edgevector.vm-disk-trim.plist" "$version/launchd/"
cp "$ROOT/bin/last-stack-host-memory-guards-install" "$version/bin/"
cp "$ROOT/launchd/com.edgevector.gui-app-memory-guard.plist" "$version/launchd/"
cp "$ROOT/launchd/com.edgevector.testbin-memory-guard.plist" "$version/launchd/"
cp "$ROOT/launchd/com.edgevector.host-memory-sentinel.plist" "$version/launchd/"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-factory-health"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-board-closeout-sweep"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-self-upgrade"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-vm-disk-trim"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-gui-app-memory-guard"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-testbin-memory-guard"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-host-memory-sentinel"
chmod +x \
  "$version/bin/last-stack-factory-health-install" \
  "$version/bin/last-stack-board-closeout-install" \
  "$version/bin/last-stack-self-upgrade-install" \
  "$version/bin/last-stack-admin-deliver-install" \
  "$version/bin/last-stack-factory-ready-buffer-install" \
  "$version/bin/last-stack-loom-reaper-install" \
  "$version/bin/last-stack-factory-health" \
  "$version/bin/last-stack-board-closeout-sweep" \
  "$version/bin/last-stack-self-upgrade" \
  "$version/bin/last-stack-vm-disk-trim-install" \
  "$version/bin/last-stack-vm-disk-trim" \
  "$version/bin/last-stack-host-memory-guards-install" \
  "$version/bin/last-stack-gui-app-memory-guard" \
  "$version/bin/last-stack-testbin-memory-guard" \
  "$version/bin/last-stack-host-memory-sentinel"

# Host Track exposes these commands through ~/.local/bin links. Every command
# must resolve that link before it loads the sibling library from the artifact.
public_bin="$tmp/public-bin"
mkdir -p "$public_bin"
for installer in \
  last-stack-admin-deliver-install \
  last-stack-board-closeout-install \
  last-stack-factory-health-install \
  last-stack-factory-ready-buffer-install \
  last-stack-host-memory-guards-install \
  last-stack-loom-reaper-install \
  last-stack-self-upgrade-install \
  last-stack-vm-disk-trim-install; do
  ln -s "$version/bin/$installer" "$public_bin/$installer"
  "$public_bin/$installer" --help >/dev/null \
    || fail "$installer failed through a public symlink"
done

# A fake launchctl that would pollute the real gui domain if called.
mkdir -p "$tmp/path"
cat >"$tmp/path/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >>"${LAUNCHCTL_LOG:?}"
[ "${1:-}" != "print" ] || [ "${FAKE_LAUNCHCTL_PRINT_FAIL:-0}" != "1" ] || exit 1
exit 0
EOF
chmod +x "$tmp/path/launchctl"
export PATH="$tmp/path:$PATH"
export LAUNCHCTL_LOG="$tmp/launchctl.log"
: >"$LAUNCHCTL_LOG"

# 1. Invoked from a version-hash tree, writes ~/.last-stack — not the hash.
out="$("$version/bin/last-stack-factory-health-install" install)" || fail "factory-health install failed"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "expected launchctl skipped, got: $out"
plist="$HOME/Library/LaunchAgents/com.edgevector.factory-health.plist"
[ -f "$plist" ] || fail "factory-health plist missing"
prog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")"
[ "$prog" = "$compat/bin/last-stack-factory-health" ] || fail "factory-health program=$prog"
root="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LAST_STACK_ROOT' "$plist")"
[ "$root" = "$compat" ] || fail "factory-health LAST_STACK_ROOT=$root"
cfg="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:FACTORY_HEALTH_CONFIG' "$plist")"
[ "$cfg" = "$compat/config/factory-health.toml" ] || fail "factory-health config=$cfg"
user="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:USER' "$plist")"
[ "$user" = "testuser" ] || fail "USER leftover REPLACE: $user"
case "$prog" in
  */artifacts/versions/*) fail "factory-health still version-pinned: $prog" ;;
esac
[ ! -s "$LAUNCHCTL_LOG" ] || fail "launchctl was called under DOMAIN=none: $(cat "$LAUNCHCTL_LOG")"

# 2. Second install is a no-op (same bytes).
out="$("$version/bin/last-stack-factory-health-install" install)" || fail "second factory-health install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "expected already current, got: $out"

# 3. board-closeout same contract.
out="$("$version/bin/last-stack-board-closeout-install" install)" || fail "board-closeout install failed"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "closeout expected skip, got: $out"
cplist="$HOME/Library/LaunchAgents/com.edgevector.board-closeout.plist"
cprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$cplist")"
[ "$cprog" = "$compat/bin/last-stack-board-closeout-sweep" ] || fail "closeout program=$cprog"
case "$cprog" in
  */artifacts/versions/*) fail "closeout still version-pinned: $cprog" ;;
esac
out="$("$version/bin/last-stack-board-closeout-install" install)" || fail "second closeout install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "closeout expected already current, got: $out"

# 3a. self-upgrade uses the same stable-root and launchctl-skip contract.
out="$("$version/bin/last-stack-self-upgrade-install" install)" \
  || fail "self-upgrade install failed"
printf '%s\n' "$out" | grep -q 'launchctl skipped' \
  || fail "self-upgrade expected skip, got: $out"
suplist="$HOME/Library/LaunchAgents/com.edgevector.last-stack-self-upgrade.plist"
suprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$suplist")"
[ "$suprog" = "$compat/bin/last-stack-self-upgrade" ] \
  || fail "self-upgrade program=$suprog"
case "$suprog" in
  */artifacts/versions/*) fail "self-upgrade still version-pinned: $suprog" ;;
esac
out="$("$version/bin/last-stack-self-upgrade-install" proof)" \
  || fail "self-upgrade proof failed under domain=none"
printf '%s\n' "$out" | grep -q 'proof: ok label=com.edgevector.last-stack-self-upgrade' \
  || fail "self-upgrade proof output=$out"
out="$("$version/bin/last-stack-self-upgrade-install" install)" \
  || fail "second self-upgrade install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "self-upgrade expected already current, got: $out"
for skip_mode in skip off; do
  export LAST_STACK_LAUNCHD_DOMAIN="$skip_mode"
  : >"$LAUNCHCTL_LOG"
  rm -f "$suplist"
  out="$("$version/bin/last-stack-self-upgrade-install" install)" \
    || fail "self-upgrade install failed for domain=$skip_mode"
  printf '%s\n' "$out" | grep -q 'launchctl skipped' \
    || fail "self-upgrade domain=$skip_mode did not skip launchctl: $out"
  [ ! -s "$LAUNCHCTL_LOG" ] \
    || fail "self-upgrade domain=$skip_mode called launchctl: $(cat "$LAUNCHCTL_LOG")"
done
export LAST_STACK_LAUNCHD_DOMAIN=none

# 3b. vm-disk-trim same contract. This agent runs `docker run --privileged
# --pid=host`, so a version-pinned program path would silently keep trimming
# from a stale tree after every refresh.
out="$("$version/bin/last-stack-vm-disk-trim-install" install)" || fail "vm-disk-trim install failed"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "vm-disk-trim expected skip, got: $out"
vplist="$HOME/Library/LaunchAgents/com.edgevector.vm-disk-trim.plist"
vprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$vplist")"
[ "$vprog" = "$compat/bin/last-stack-vm-disk-trim" ] || fail "vm-disk-trim program=$vprog"
case "$vprog" in
  */artifacts/versions/*) fail "vm-disk-trim still version-pinned: $vprog" ;;
esac
vuser="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:USER' "$vplist")"
[ "$vuser" = "testuser" ] || fail "vm-disk-trim USER leftover REPLACE: $vuser"
out="$("$version/bin/last-stack-vm-disk-trim-install" install)" || fail "second vm-disk-trim install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "vm-disk-trim expected already current, got: $out"
: >"$LAUNCHCTL_LOG"
"$version/bin/last-stack-vm-disk-trim-install" uninstall >/dev/null
[ ! -f "$vplist" ] || fail "vm-disk-trim uninstall left the plist"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "vm-disk-trim uninstall called launchctl: $(cat "$LAUNCHCTL_LOG")"

# 3c. host-memory-guards same contract (three plists, bash + script argv).
# A version-pinned path would drop crash protection after every refresh.
out="$("$version/bin/last-stack-host-memory-guards-install" install)" \
  || fail "host-memory-guards install failed"
printf '%s\n' "$out" | grep -q 'launchctl skipped' \
  || fail "host-memory-guards expected skip, got: $out"
hplist="$HOME/Library/LaunchAgents/com.edgevector.gui-app-memory-guard.plist"
hprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$hplist")"
[ "$hprog" = "$compat/bin/last-stack-gui-app-memory-guard" ] \
  || fail "gui-app-memory-guard program=$hprog"
case "$hprog" in
  */artifacts/versions/*) fail "gui-app-memory-guard still version-pinned: $hprog" ;;
esac
tplist="$HOME/Library/LaunchAgents/com.edgevector.testbin-memory-guard.plist"
tprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$tplist")"
[ "$tprog" = "$compat/bin/last-stack-testbin-memory-guard" ] \
  || fail "testbin-memory-guard program=$tprog"
splist="$HOME/Library/LaunchAgents/com.edgevector.host-memory-sentinel.plist"
sprog="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$splist")"
[ "$sprog" = "$compat/bin/last-stack-host-memory-sentinel" ] \
  || fail "host-memory-sentinel program=$sprog"
out="$("$version/bin/last-stack-host-memory-guards-install" install)" \
  || fail "second host-memory-guards install failed"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' \
  || fail "host-memory-guards expected already current, got: $out"
: >"$LAUNCHCTL_LOG"
"$version/bin/last-stack-host-memory-guards-install" uninstall >/dev/null
[ ! -f "$hplist" ] || fail "host-memory-guards uninstall left a plist"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "host-memory-guards uninstall called launchctl: $(cat "$LAUNCHCTL_LOG")"

# 4. Foreign HOME + default domain must not call launchctl (gui-domain leak).
unset LAST_STACK_LAUNCHD_DOMAIN
: >"$LAUNCHCTL_LOG"
# Change a comment-free field so commit would otherwise want to load.
# (plist already current — force a rewrite by deleting and reinstalling)
rm -f "$plist"
out="$("$version/bin/last-stack-factory-health-install" install)" || fail "foreign-home install failed"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "launchctl leaked into real gui domain: $(cat "$LAUNCHCTL_LOG")"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "foreign home should skip launchctl, got: $out"

rm -f "$suplist"
out="$("$version/bin/last-stack-self-upgrade-install" install)" \
  || fail "foreign-home self-upgrade install failed"
[ ! -s "$LAUNCHCTL_LOG" ] \
  || fail "self-upgrade launchctl leaked into real gui domain: $(cat "$LAUNCHCTL_LOG")"
printf '%s\n' "$out" | grep -q 'launchctl skipped' \
  || fail "foreign-home self-upgrade should skip launchctl, got: $out"

# 4b. Simulate the uid's real home. Only the self-upgrade label may load.
cat >"$tmp/path/dscl" <<'EOF'
#!/bin/sh
printf 'NFSHomeDirectory: %s\n' "${FAKE_REAL_HOME:?}"
EOF
chmod +x "$tmp/path/dscl"
export FAKE_REAL_HOME="$HOME"
: >"$LAUNCHCTL_LOG"
rm -f "$suplist"
out="$("$version/bin/last-stack-self-upgrade-install" install)" \
  || fail "real-home self-upgrade install failed"
printf '%s\n' "$out" | grep -q 'loaded com.edgevector.last-stack-self-upgrade' \
  || fail "real-home self-upgrade did not load: $out"
[ "$(wc -l <"$LAUNCHCTL_LOG" | tr -d ' ')" = "4" ] \
  || fail "real-home self-upgrade launchctl call count: $(cat "$LAUNCHCTL_LOG")"
if grep -v 'com.edgevector.last-stack-self-upgrade' "$LAUNCHCTL_LOG" >/dev/null; then
  fail "real-home self-upgrade loaded another label: $(cat "$LAUNCHCTL_LOG")"
fi
: >"$LAUNCHCTL_LOG"
out="$("$version/bin/last-stack-self-upgrade-install" proof)" \
  || fail "real-home self-upgrade proof failed"
printf '%s\n' "$out" | grep -q 'proof: ok label=com.edgevector.last-stack-self-upgrade' \
  || fail "real-home self-upgrade proof output=$out"
grep -q "launchctl print gui/$(id -u)/com.edgevector.last-stack-self-upgrade" \
  "$LAUNCHCTL_LOG" || fail "proof did not query the intended label: $(cat "$LAUNCHCTL_LOG")"
export FAKE_LAUNCHCTL_PRINT_FAIL=1
if out="$("$version/bin/last-stack-self-upgrade-install" proof 2>&1)"; then
  fail "self-upgrade proof passed while the service was missing"
fi
printf '%s\n' "$out" | grep -q 'proof: service not loaded label=com.edgevector.last-stack-self-upgrade' \
  || fail "missing-service proof was not clear: $out"
unset FAKE_LAUNCHCTL_PRINT_FAIL

# 5. Uninstall with domain=none removes plist and still does not call launchctl.
export LAST_STACK_LAUNCHD_DOMAIN=none
: >"$LAUNCHCTL_LOG"
"$version/bin/last-stack-factory-health-install" uninstall >/dev/null
[ ! -f "$plist" ] || fail "uninstall left factory-health plist"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "uninstall called launchctl: $(cat "$LAUNCHCTL_LOG")"
"$version/bin/last-stack-self-upgrade-install" uninstall >/dev/null
[ ! -f "$suplist" ] || fail "uninstall left self-upgrade plist"
[ ! -s "$LAUNCHCTL_LOG" ] \
  || fail "self-upgrade uninstall called launchctl: $(cat "$LAUNCHCTL_LOG")"

echo "ok last-stack-launchagent-stable-path"
