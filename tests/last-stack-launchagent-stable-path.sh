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
cp "$ROOT/lib/last-stack-launchd-agent.sh" "$version/lib/"
cp "$ROOT/launchd/com.edgevector.factory-health.plist" "$version/launchd/"
cp "$ROOT/launchd/com.edgevector.board-closeout.plist" "$version/launchd/"
cp "$ROOT/bin/last-stack-vm-disk-trim-install" "$version/bin/"
cp "$ROOT/launchd/com.edgevector.vm-disk-trim.plist" "$version/launchd/"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-factory-health"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-board-closeout-sweep"
printf '#!/bin/sh\nexit 0\n' >"$version/bin/last-stack-vm-disk-trim"
chmod +x \
  "$version/bin/last-stack-factory-health-install" \
  "$version/bin/last-stack-board-closeout-install" \
  "$version/bin/last-stack-factory-health" \
  "$version/bin/last-stack-board-closeout-sweep" \
  "$version/bin/last-stack-vm-disk-trim-install" \
  "$version/bin/last-stack-vm-disk-trim"

# A fake launchctl that would pollute the real gui domain if called.
mkdir -p "$tmp/path"
cat >"$tmp/path/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >>"${LAUNCHCTL_LOG:?}"
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

# 4. Foreign HOME + default domain must not call launchctl (gui-domain leak).
unset LAST_STACK_LAUNCHD_DOMAIN
: >"$LAUNCHCTL_LOG"
# Change a comment-free field so commit would otherwise want to load.
# (plist already current — force a rewrite by deleting and reinstalling)
rm -f "$plist"
out="$("$version/bin/last-stack-factory-health-install" install)" || fail "foreign-home install failed"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "launchctl leaked into real gui domain: $(cat "$LAUNCHCTL_LOG")"
printf '%s\n' "$out" | grep -q 'launchctl skipped' || fail "foreign home should skip launchctl, got: $out"

# 5. Uninstall with domain=none removes plist and still does not call launchctl.
export LAST_STACK_LAUNCHD_DOMAIN=none
: >"$LAUNCHCTL_LOG"
"$version/bin/last-stack-factory-health-install" uninstall >/dev/null
[ ! -f "$plist" ] || fail "uninstall left factory-health plist"
[ ! -s "$LAUNCHCTL_LOG" ] || fail "uninstall called launchctl: $(cat "$LAUNCHCTL_LOG")"

echo "ok last-stack-launchagent-stable-path"
