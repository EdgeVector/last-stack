#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

"$ROOT/bin/last-stack-audit-f-prefix-callers"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp -R "$ROOT/bin" "$tmp/bin"
cp -R "$ROOT/routines" "$tmp/routines"
cp -R "$ROOT/skills" "$tmp/skills"
cp -R "$ROOT/templates" "$tmp/templates"
cp -R "$ROOT/harness" "$tmp/harness"
cp -R "$ROOT/hooks" "$tmp/hooks"
cp -R "$ROOT/instructions" "$tmp/instructions"
mkdir -p "$tmp/.lastgit"
cp "$ROOT/.lastgit/ci.sh" "$tmp/.lastgit/ci.sh"
cp "$ROOT/CLAUDE.md" "$tmp/CLAUDE.md"

mkdir -p "$tmp/routines"
printf '%s\n' 'fkanban list --column todo --json' >"$tmp/routines/bad.md"

if "$tmp/bin/last-stack-audit-f-prefix-callers" >/dev/null 2>&1; then
  echo "expected active fkanban caller audit to fail" >&2
  exit 1
fi

echo "PASS last-stack-audit-f-prefix-callers"
