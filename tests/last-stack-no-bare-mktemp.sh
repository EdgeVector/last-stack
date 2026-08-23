#!/usr/bin/env bash
# Static gate: no helper in bin/ may call bare `mktemp`.
#
# Bare `mktemp` on Darwin resolves to the per-user temp dir (confstr
# DARWIN_USER_TEMP_DIR) and IGNORES TMPDIR; scheduled routine sandboxes deny
# that path, which made helpers fail hourly until each run hand-built a shim
# (papercut-routine-mktemp-tempdir-env-denied-20260821,
# papercut-worktree-reclaim-helper-ignores-routine-tmpdir).
# Every mktemp call must pass an explicit template, e.g.:
#   mktemp "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack.XXXXXX"
# The rule enforced here: any line mentioning mktemp must either carry an
# XXXXXX template or be a comment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

violations="$(grep -rnE '\bmktemp\b' "$ROOT/bin" 2>/dev/null \
  | grep -v 'XXXXXX' \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)"

if [ -n "$violations" ]; then
  echo "FAIL: bare mktemp without an explicit template (sandbox-denied on Darwin):"
  printf '%s\n' "$violations"
  exit 1
fi

echo "PASS last-stack-no-bare-mktemp"
