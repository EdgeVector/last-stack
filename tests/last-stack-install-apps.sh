#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

stubbin="$tmp/bin"
mkdir -p "$stubbin"

cat >"$stubbin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${BREW_LOG:?}"
printf '%s\n' "brew $*" >>"$log"
case "$1" in
  tap)
    if [ "$#" -eq 1 ]; then
      printf '%s\n' "antoniorodr/memo" "openclaw/tap" "steipete/tap" "yakitrak/yakitrak"
      exit 0
    fi
    exit 0
    ;;
  trust)
    if [ "${2:-}" = "--help" ]; then
      cat <<'HELP'
Usage: brew trust [options] [target ...]
      --tap, --taps                Trust the named tap.
      --formula, --formulae        Trust the named formula.
HELP
      exit 0
    fi
    exit 0
    ;;
  install)
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$stubbin/brew"

cat >"$stubbin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "clone" ]; then
  dest="$3"
  mkdir -p "$dest/.git"
  exit 0
fi
echo "unexpected git command: $*" >&2
exit 1
EOF
chmod +x "$stubbin/git"

cat >"$stubbin/bun" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stubbin/bun"

BREW_LOG="$tmp/brew.log" PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps" --no-link >/tmp/last-stack-install-apps.out

grep -Fxq 'brew tap' "$tmp/brew.log"
grep -Fxq 'brew tap edgevector/lastdb' "$tmp/brew.log"
grep -Fxq 'brew trust --tap edgevector/lastdb' "$tmp/brew.log"
grep -Fxq 'brew install edgevector/lastdb/lastdb' "$tmp/brew.log"
if grep -Eq 'brew trust .*antoniorodr|brew trust .*openclaw|brew trust .*steipete|brew trust .*yakitrak' "$tmp/brew.log"; then
  echo "trusted an unrelated tap" >&2
  exit 1
fi

echo "ok"
