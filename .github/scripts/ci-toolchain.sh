#!/usr/bin/env bash
# Toolchain the last-stack test suite expects on a GitHub macOS runner.
# The former Forge host lane had these on PATH already.
set -euo pipefail
git config --global user.name "ci"
git config --global user.email "ci@example.invalid"
git config --global init.defaultBranch main
for tool in jq python3 git gh curl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
missing=()
command -v rg >/dev/null || missing+=(ripgrep)
command -v gdate >/dev/null || missing+=(coreutils)
command -v shellcheck >/dev/null || missing+=(shellcheck)
if [ "${#missing[@]}" -gt 0 ]; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "${missing[@]}"
fi
bash --version | head -1
jq --version
python3 --version
bun --version
