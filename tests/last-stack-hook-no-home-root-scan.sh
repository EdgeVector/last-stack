#!/usr/bin/env bash
set -euo pipefail

# The home-root guard exists because a walk of $HOME steps into the macOS
# TCC-protected folders. Under routinesd the prompt is attributed to `routines`
# and the command BLOCKS until a human clicks it — measured 2026-09-05, and the
# cause of three "find $HOME hung past N min" papercuts.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/no-home-root-scan.sh"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

[ -x "$HOOK" ] || { echo "hooks/no-home-root-scan.sh must ship executable" >&2; exit 1; }

# The hook must be readable on any machine: no personal home path baked in.
if grep -q '/Users/[a-z]' "$HOOK"; then
  echo "hook must not hard-code a personal home path" >&2
  exit 1
fi

# Answer for one Bash command: DENY or ALLOW.
verdict() {
  local out
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(jq -Rn --arg c "$1" '$c')" | HOME="$tmp" bash "$HOOK")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf 'DENY\n'
  else
    printf 'ALLOW\n'
  fi
}

expect() {
  local want="$1" cmd="$2" got
  got="$(verdict "$cmd")"
  if [ "$got" != "$want" ]; then
    echo "expected $want, got $got for: $cmd" >&2
    exit 1
  fi
}

# Walks of the home root, in every spelling an agent reaches for.
expect DENY "find $tmp -maxdepth 4 -type d -name artifacts"
expect DENY 'find "$HOME" -maxdepth 4 -name artifacts'
expect DENY 'find $HOME -maxdepth 3 -iname "*fkanban*"'
expect DENY 'du -sh ~/*'
expect DENY 'rg --files ~ | head'

# Direct reads of a protected personal folder.
expect DENY 'cat ~/Downloads/report.csv'
expect DENY 'ls ~/Desktop'
expect DENY 'find "$HOME/Documents" -name notes.md'

# Scoped work roots stay allowed — the guard must not block real routine work.
expect ALLOW 'find ~/code -maxdepth 4 -name .git'
expect ALLOW 'find "$HOME/.last-stack" "$HOME/.routines" -maxdepth 3 -name run.sh'
expect ALLOW 'grep -rn foo ~/.routines/bin'
expect ALLOW 'ls ~/.fkanban/worktrees'
expect ALLOW 'du -sh ~/.cache/*'

# A path that merely starts with the home string is not the home root.
expect ALLOW 'find "$HOME/code" -maxdepth 2 -name x'

# Deliberate use passes with a stated reason.
expect ALLOW 'find "$HOME" -maxdepth 2  # home-scan-ok: auditing top-level layout'

# The deny message must hand back a runnable replacement, not only a rule.
msg="$(printf '{"tool_name":"Bash","tool_input":{"command":"find $HOME -name x"}}' \
  | HOME="$tmp" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
printf '%s' "$msg" | grep -q -- '-prune' || {
  echo "deny message must show the pruned home walk" >&2; exit 1; }
printf '%s' "$msg" | grep -q 'home-scan-ok' || {
  echo "deny message must name the escape hatch" >&2; exit 1; }

# setup must ship and register the hook, and carry the instruction block.
grep -q 'no-home-root-scan.sh' "$ROOT/setup" || {
  echo "setup must install hooks/no-home-root-scan.sh" >&2; exit 1; }
grep -q 'instructions/no-home-root-scan.md' "$ROOT/setup" || {
  echo "setup must append the no-home-root-scan instruction block" >&2; exit 1; }
[ -f "$ROOT/instructions/no-home-root-scan.md" ] || {
  echo "instructions/no-home-root-scan.md must exist" >&2; exit 1; }

echo "ok last-stack-hook-no-home-root-scan"
