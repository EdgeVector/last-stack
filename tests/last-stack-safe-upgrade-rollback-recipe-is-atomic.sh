#!/usr/bin/env bash
# Regression: the rollback recipe the driver PRINTS must be the atomic one.
#
# The fixed recipe living in SKILL.md is not enough. The broken one was printed
# to the terminal, pre-filled with real paths and the real version stamp, under
# the heading an operator scans for when the new binary misbehaves -- i.e. it is
# reached exactly when the primary is already bad. An in-place `cp -a` onto the
# live path keeps the destination inode, macOS still holds the cached code
# signature for that inode, and the kernel kills every exec with
# OS_REASON_CODESIGNING. That took the primary down on 2026-07-27.
#
# Papercut: papercut-lastdb-safe-upgrade-rollback-cp-a-trips-codesigning
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
bash -n "$driver"

# The printed sidebin rollback block, from its heading to the kickstart line.
block="$(awk '
  /ROLLBACK \(binary only/ { grab=1 }
  grab { print }
  grab && /launchctl kickstart/ { exit }
' "$driver")"

if [ -z "$block" ]; then
  echo "FAIL: could not find the printed ROLLBACK block in $driver" >&2
  exit 1
fi

# The trap: `cp -a <something> <dir>/lastdbd` or `<dir>/lastdb` with no temp
# suffix. A safe line copies to `.lastdbd.rollback.tmp` instead.
if printf '%s\n' "$block" | grep -Eq 'cp -a [^"]*\$SIDEBIN_DIR/lastdbd?"?[[:space:]]'; then
  echo "FAIL: the printed rollback recipe copies straight onto the live path." >&2
  echo "      That is OS_REASON_CODESIGNING and a dead primary. Copy to" >&2
  echo "      .lastdbd.rollback.tmp, codesign --force --sign -, assert" >&2
  echo "      --version, then mv -f into place." >&2
  printf '%s\n' "$block" >&2
  exit 1
fi

# And it must positively carry every step of the safe recipe, so the guard
# cannot be satisfied by simply deleting the rollback advice.
for needle in \
  '.lastdbd.rollback.tmp' \
  'codesign --force --sign -' \
  'xattr -c' \
  '--version' \
  'mv -f'
do
  if ! printf '%s\n' "$block" | grep -qF -- "$needle"; then
    echo "FAIL: printed rollback recipe is missing '$needle'" >&2
    printf '%s\n' "$block" >&2
    exit 1
  fi
done

echo "OK: printed rollback recipe is the atomic re-sign form"
