#!/usr/bin/env bash
# shellcheck shell=bash
# Give Python a writable bytecode cache before any `python3 -m py_compile`.
#
# The host python3 (Apple's 3.9) defaults its cache prefix to
# ~/Library/Caches/com.apple.python/<absolute source path>. The routine and
# pickup sandboxes deny that folder, so a test run from a DEV worktree failed
# with `PermissionError: [Errno 1] Operation not permitted` before its first
# assertion. .lastgit/ci.sh already set a prefix, so the gate was green while
# the same test run alone was red. Source this file from any test or helper
# that compiles Python; an explicit PYTHONPYCACHEPREFIX still wins.
# papercut-python-pycompile-cache-tcc-denies-worktree
if [ -z "${PYTHONPYCACHEPREFIX:-}" ]; then
  PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}"
  PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX%/}/last-stack-pycache-$(id -u)"
  mkdir -p "$PYTHONPYCACHEPREFIX" 2>/dev/null || true
  export PYTHONPYCACHEPREFIX
fi
