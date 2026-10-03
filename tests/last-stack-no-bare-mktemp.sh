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
# The rule enforced here: any line that CALLS mktemp must either carry an XXXXXX
# template or be a comment.
#
# The matcher used to be `\bmktemp\b`, which is a mention and not a call: `-` is a
# word boundary, so a hyphenated identifier such as a lint rule id named
# `mktemp-suffix` was flagged as a bare call. The promise in the header line above
# says "call"; match that instead. A line that legitimately carries mktemp syntax
# without a literal template -- a regex that recognises mktemp calls, for instance
# -- states its reason with `# mktemp-ok: <reason>`, the same escape convention as
# `# walk-ok:` in last-stack-lint-bin-authoring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A call: the name is not part of a longer identifier on either side. `.` and `-`
# are excluded so neither `mktemp-suffix` nor `re_mktemp_suffix` reads as a call.
violations="$(grep -rnE '(^|[^[:alnum:]_.-])mktemp([^[:alnum:]_.-]|$)' "$ROOT/bin" 2>/dev/null \
  | grep -v 'XXXXXX' \
  | grep -v 'mktemp-ok:' \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)"

if [ -n "$violations" ]; then
  echo "FAIL: bare mktemp without an explicit template (sandbox-denied on Darwin):"
  printf '%s\n' "$violations"
  exit 1
fi

echo "PASS last-stack-no-bare-mktemp"
