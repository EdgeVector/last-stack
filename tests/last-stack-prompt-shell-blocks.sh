#!/usr/bin/env bash
# Every fenced bash/sh/zsh block in a routine prompt, skill or instruction
# block must pass bin/last-stack-routine-shell-lint (bash rules). Agents copy
# these blocks; a bad shape in a prompt comes back as a papercut per run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LINT="$ROOT/bin/last-stack-routine-shell-lint"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-shell-blocks.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cd "$ROOT"
for f in routines/*.md skills/*/SKILL.md instructions/*.md; do
  [ -f "$f" ] || continue
  awk -v F="$f" -v B="$tmp" '
    /^[[:space:]]*```(bash|sh|zsh)[[:space:]]*$/ { inb = 1; n++; buf = ""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ {
      inb = 0; out = F "#" n; gsub("/", "_", out)
      printf "%s", buf > (B "/" out); close(B "/" out); next
    }
    inb { buf = buf $0 "\n" }
  ' "$f"
done

count=0
bad=0
for block in "$tmp"/*; do
  [ -f "$block" ] || continue
  count=$((count + 1))
  if ! "$LINT" --shell bash < "$block" 2> "$block.err"; then
    echo "FAIL $(basename "$block"): $(head -n 1 "$block.err")" >&2
    bad=$((bad + 1))
  fi
done
[ "$count" -gt 0 ] || { echo "FAIL no fenced shell blocks found" >&2; exit 1; }
[ "$bad" -eq 0 ] || exit 1
echo "ok prompt shell blocks: $count checked"
