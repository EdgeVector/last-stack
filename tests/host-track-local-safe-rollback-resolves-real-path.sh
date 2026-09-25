#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Verify that the rollback_local_safe_app function in host-track prefers
# $ROOT/bin/last-stack-safe-activate-cli over PATH-based lookup.
# This ensures that after maybe_reexec_for_mutation, the helper is resolved
# from the real installed location, not from a temporary directory.

# Extract the activate_bin resolution logic from the rollback_local_safe_app function
activate_bin_logic="$(
  sed -n '/^rollback_local_safe_app()/,/^}/p' "$ROOT/bin/host-track" | \
  grep -A 2 'activate_bin='
)"

# Check that $ROOT/bin is checked FIRST (before command -v)
echo "$activate_bin_logic" | grep -q 'activate_bin="$ROOT/bin/last-stack-safe-activate-cli"' || \
  fail "activate_bin resolution does not prefer \$ROOT/bin"

# Verify the fallback to command -v comes AFTER the $ROOT check
if ! echo "$activate_bin_logic" | head -n 1 | grep -q 'ROOT/bin'; then
  fail "activate_bin does not prefer \$ROOT/bin as first choice"
fi

# Verify that command -v is only used as fallback (conditional check)
echo "$activate_bin_logic" | grep -q '|| activate_bin="$(command -v' || \
  fail "activate_bin does not have fallback to command -v"

printf 'PASS host-track local-safe rollback resolves helper from real path\n'
