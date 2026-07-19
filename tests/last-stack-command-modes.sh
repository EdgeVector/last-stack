#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

fail=0
while IFS= read -r path; do
  mode="$(git ls-files -s -- "$path" | awk '{print $1}')"
  if [ "$mode" != "100755" ]; then
    printf 'expected executable git mode 100755 for %s, got %s\n' "$path" "${mode:-missing}" >&2
    fail=1
  fi
  if [ ! -x "$path" ]; then
    printf 'expected working-tree executable bit for %s\n' "$path" >&2
    fail=1
  fi
done <<'EOF'
setup
bin/last-stack-north-star-completion-check
tests/last-stack-command-modes.sh
EOF

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS last-stack-command-modes"
