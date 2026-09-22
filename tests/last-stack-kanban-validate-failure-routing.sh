#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROMPT="$ROOT/routines/kanban-validate.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^- \*\*FAIL:\*\*/ { in_fail = 1 }
  in_fail { print }
  /^- \*\*BLOCKED \(upstream\):\*\*/ { exit }
' "$PROMPT" >"$tmp/fail-section.md"

grep -q 'kanban milestone add <milestone-slug> --proof-status failing --json' \
  "$tmp/fail-section.md"
grep -q 'do not file a fix card from this routine' "$tmp/fail-section.md"
grep -q 'do not append the same failure line twice' "$tmp/fail-section.md"
grep -q 'If no parent milestone exists' "$tmp/fail-section.md"
grep -q 'last-stack-kanban-file-pr' "$tmp/fail-section.md"
grep -q 'fix=<fix-slug>' "$tmp/fail-section.md"
grep -q 'no-milestone exception files a card' "$tmp/fail-section.md"

printf '%s\n' 'ok: kanban-validate failure routing is milestone-first'
