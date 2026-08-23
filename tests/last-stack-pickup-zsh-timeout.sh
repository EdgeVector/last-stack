#!/usr/bin/env bash
# Class A pickup freshness must invoke timeout as argv words. A scalar
# `_to="timeout -k 3s 20s"; $_to cmd` is one command name under zsh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
pickup="$ROOT/routines/kanban-pickup.md"

if grep -E '^[[:space:]]*_to="(g?timeout) -k' "$pickup"; then
  echo "FAIL: pickup still stores a multi-word timeout command in a scalar" >&2
  exit 1
fi
grep -q 'timeout -k 3s 20s "$_heal_bin"' "$pickup"
grep -q 'gtimeout -k 3s 20s "$_heal_bin"' "$pickup"

if command -v zsh >/dev/null 2>&1; then
  # Prove the old scalar form is the zsh 127, and the argv form runs.
  if zsh -c '_to="true -k 3s 20s"; $_to' 2>/dev/null; then
    echo "FAIL: unexpected: zsh word-split a multi-word scalar" >&2
    exit 1
  fi
  # argv form: `true` is the command, flags are args. `true` ignores them.
  zsh -c 'true -k 3s 20s; echo ok-argv' | grep -q ok-argv
fi

echo "ok last-stack-pickup-zsh-timeout"
