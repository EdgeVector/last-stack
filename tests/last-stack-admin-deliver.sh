#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$tmp/home"
export USER=testuser
export LAST_STACK_PUBLIC_ROOT="$ROOT"
export LAST_STACK_LAUNCHD_DOMAIN=none
export ADMIN_DELIVER_PLIST_DIR="$HOME/Library/LaunchAgents"
export ADMIN_DELIVER_RECIPIENT_ENV="$HOME/.lastdb/admin-deliver-recipient.env"
mkdir -p "$HOME/.lastdb" "$HOME/bin" "$ADMIN_DELIVER_PLIST_DIR"
cat >"$ADMIN_DELIVER_RECIPIENT_ENV" <<'EOF'
ROUTINES_ADMIN_RECIPIENT_PUBKEY=test-recipient
FBRAIN_ADMIN_RECIPIENT_PUBKEY=test-recipient
EOF
cat >"$HOME/bin/brain" <<'EOF'
#!/bin/sh
printf 'brain:%s:%s\n' "$*" "${FBRAIN_ADMIN_RECIPIENT_PUBKEY:-missing}"
EOF
cat >"$HOME/bin/routines" <<'EOF'
#!/bin/sh
printf 'routines:%s:%s\n' "$*" "${ROUTINES_ADMIN_RECIPIENT_PUBKEY:-missing}"
EOF
chmod +x "$HOME/bin/brain" "$HOME/bin/routines"
export PATH="$HOME/bin:$PATH"

out="$("$ROOT/bin/last-stack-admin-deliver" brain --dry-run)"
[ "$out" = 'brain:admin-snapshot deliver --dry-run:test-recipient' ] || fail "$out"
out="$("$ROOT/bin/last-stack-admin-deliver" routines --approve)"
[ "$out" = 'routines:deliver-status --approve:test-recipient' ] || fail "$out"

"$ROOT/bin/last-stack-admin-deliver-install" install >/dev/null
for mode in brain routines; do
  case "$mode" in
    brain) label=com.edgevector.admin-brain-snapshot; run_home="$HOME/.local/share/edgevector/admin-brain-snapshot" ;;
    routines) label=com.edgevector.admin-routines-status; run_home="$HOME/.local/share/edgevector/admin-routines-status" ;;
  esac
  [ -x "$run_home/run.sh" ] || fail "$mode run.sh missing"
  [ -f "$run_home/README.md" ] || fail "$mode README missing"
  [ -f "$run_home/launchd/$label.plist" ] || fail "$mode RUN-home plist missing"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$ADMIN_DELIVER_PLIST_DIR/$label.plist")" = "$label" ] || fail "$mode label"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$ADMIN_DELIVER_PLIST_DIR/$label.plist")" = 3600 ] || fail "$mode interval"
done

out="$("$ROOT/bin/last-stack-admin-deliver-install" install)"
printf '%s\n' "$out" | grep -q 'already current, skipped launchctl' || fail "second install not idempotent: $out"
echo "ok last-stack-admin-deliver"
