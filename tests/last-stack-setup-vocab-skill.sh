#!/usr/bin/env bash
# setup installs the user-vocabulary skill for Claude, Codex, and Grok.
# Uninstall removes that skill. Pass one host name to run one case.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
host="${1:-all}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

skills_rel_for() {
  case "$1" in
    claude) printf '%s\n' ".claude/skills" ;;
    codex) printf '%s\n' ".codex/skills" ;;
    grok) printf '%s\n' ".grok/skills" ;;
    *) fail "unknown host $1" ;;
  esac
}

run_host() {
  local name="$1"
  local rel skill tmp
  rel="$(skills_rel_for "$name")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vocab-skill.XXXXXX")"
  (
    export HOME="$tmp/home"
    mkdir -p "$HOME"
    "$ROOT/setup" --host "$name" >"$tmp/setup.out" 2>&1 || {
      cat "$tmp/setup.out" >&2
      fail "$name setup exited non-zero"
    }
    skill="$HOME/$rel/user-vocabulary/SKILL.md"
    [ -f "$skill" ] || fail "$name skill missing"
    grep -q 'last-stack-vocab add' "$skill" || fail "$name skill has no add command"
    grep -q 'name: user-vocabulary' "$skill" || fail "$name skill name drifted"
    "$ROOT/setup" --uninstall >"$tmp/uninstall.out" 2>&1 || {
      cat "$tmp/uninstall.out" >&2
      fail "$name uninstall exited non-zero"
    }
    if [ -e "$skill" ]; then
      fail "uninstall left the $name skill"
    fi
  )
  rm -rf "$tmp"
  echo "ok vocab skill $name"
}

case "$host" in
  all)
    run_host claude
    run_host codex
    run_host grok
    ;;
  claude|codex|grok) run_host "$host" ;;
  *) fail "unknown host $host" ;;
esac
echo "PASS last-stack-setup-vocab-skill ($host)"
