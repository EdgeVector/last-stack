#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
stubbin="$tmp/bin"
mkdir -p "$HOME" "$stubbin"

cat >"$stubbin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = clone ]; then
  dest="$3"
  mkdir -p "$dest/.git" "$dest/bin"
  printf '#!/bin/sh\nexit 0\n' >"$dest/bin/routines"
  chmod +x "$dest/bin/routines"
  exit 0
fi
if [ "$1" = -C ] && [ "$3" = pull ] && [ "$4" = --ff-only ]; then
  exit 0
fi
echo "unexpected git command: $*" >&2
exit 1
EOF

cat >"$stubbin/bun" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stubbin/git" "$stubbin/bun"

PATH="$stubbin:/usr/bin:/bin" \
  LAST_STACK_ROUTINES_INSTALL_ROOT="$tmp/apps/routines" \
  "$ROOT/bin/last-stack-install-routines" >"$tmp/first.out"

test "$(readlink "$HOME/.local/bin/routines")" = "$tmp/apps/routines/bin/routines"
grep -q 'routines install-daemon' "$tmp/first.out"

PATH="$stubbin:/usr/bin:/bin" \
  LAST_STACK_ROUTINES_INSTALL_ROOT="$tmp/apps/routines" \
  "$ROOT/bin/last-stack-install-routines" >"$tmp/second.out"
grep -q 'updating routines' "$tmp/second.out"

# Prove main setup invokes the bootstrap instead of merely documenting it.
grep -q '^install_routines_cli() {' "$ROOT/setup"
grep -q '^install_routines_cli$' "$ROOT/setup"

echo "ok last-stack-install-routines"
