#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
prompt="$ROOT/routines/papercut-reconciler.md"

grep -q 'papercut-prevention-registry' "$prompt"
grep -q 'Prevention: MISSING|COVERED|NOT_APPLICABLE' "$prompt"
grep -q 'compound regression test' "$prompt"
grep -q 'COMPOUND PREVENTION' "$prompt"
grep -q 'red-before/green-after proof' "$prompt"
grep -q 'Documentation alone is never prevention coverage' "$prompt"

printf 'ok last-stack-papercut-reconciler-contract\n'
