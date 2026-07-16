#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$ROOT/skills/machine-hygiene/SKILL.md"

if grep -En 'for [^[:space:]]+ in /Volumes/LastDB\*|for [^[:space:]]+ in /private/tmp/cv\.\*' "$skill"; then
  echo "machine-hygiene must not use bare zsh-fatal temp/volume globs" >&2
  exit 1
fi

grep -Fq "find /Volumes -maxdepth 1 -type d -name 'LastDB*'" "$skill"

if command -v zsh >/dev/null 2>&1; then
  zsh -fc '
    set -e
    find /definitely-missing-last-stack-volume-root -maxdepth 1 -type d -name '"'"'LastDB*'"'"' -print 2>/dev/null |
      while IFS= read -r v; do hdiutil detach "$v" 2>/dev/null || true; done
    print ok
  ' | grep -qx ok
fi

echo "ok"
