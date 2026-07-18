#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

make_plist() {
  local label="$1" path="$2"
  local plist="$tmp/com.edgevector.$label.plist"
  /usr/libexec/PlistBuddy -c "Add :Label string com.edgevector.$label" "$plist" >/dev/null 2>&1 || true
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.edgevector.$label</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$path</string>
	</dict>
</dict>
</plist>
PLIST
}

# Homebrew ahead of Apple git — the buggy case this script exists to catch.
make_plist broken "/Users/tomtang/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# Already correct — must be left untouched and reported OK, not FIXED.
make_plist clean "/Users/tomtang/.local/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin"
# No EnvironmentVariables:PATH key at all — must be skipped silently, not error.
cat >"$tmp/com.edgevector.no-path.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.edgevector.no-path</string>
</dict>
</plist>
PLIST

# Dry-run: reports NEEDS_FIX/OK, never writes, exit code counts fixes needed.
out="$("$ROOT/bin/last-stack-launchd-path-audit" --dir "$tmp")" && rc=0 || rc=$?
echo "$out" | grep -q 'NEEDS_FIX com.edgevector.broken'
echo "$out" | grep -q 'OK com.edgevector.clean'
! echo "$out" | grep -q 'no-path'
test "$rc" = 1

unchanged="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$tmp/com.edgevector.broken.plist")"
test "$unchanged" = "/Users/tomtang/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# --fix: reorders in place, preserves every other entry's relative order.
"$ROOT/bin/last-stack-launchd-path-audit" --fix --dir "$tmp" >/dev/null
fixed="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$tmp/com.edgevector.broken.plist")"
test "$fixed" = "/Users/tomtang/.local/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin"

clean_untouched="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$tmp/com.edgevector.clean.plist")"
test "$clean_untouched" = "/Users/tomtang/.local/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin"

# Idempotent: a second --fix pass makes no further changes and exits clean.
"$ROOT/bin/last-stack-launchd-path-audit" --dir "$tmp" >/dev/null && rc2=0 || rc2=$?
test "$rc2" = 0

echo "last-stack-launchd-path-audit.sh: ok"
