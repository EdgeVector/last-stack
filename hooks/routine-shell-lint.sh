#!/usr/bin/env bash
# PreToolUse hook (Claude Code, matcher Bash). Denies a command shape that
# fails on this host in a known way, and hands back the fix in the same turn.
# The rules live in bin/last-stack-routine-shell-lint (one source for Codex
# routines, Claude sessions and the prompt lint). Claude Code runs Bash in
# zsh, so this hook also checks the zsh-only rules (status, mapfile).
#
# Main case (measured 2026-09-22): Claude Code blocks a foreground `sleep`,
# so agents wrote `read -t 20 < /dev/zero` as a delay. It returns at once,
# and each wait loop burned one full core for up to 10 minutes on a host
# with load 120-150 (papercut-agent-spin-wait-read-t-dev-zero-20260922).
#
# Fails open: bad input, no jq, or no lint means allow.
# Escape hatch: "shell-lint-ok: <reason>" in the command.
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

lint="${LAST_STACK_ROUTINE_SHELL_LINT:-$HOME/.last-stack/bin/last-stack-routine-shell-lint}"
[ -x "$lint" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

reason="$(printf '%s' "$cmd" | "$lint" --shell zsh 2>&1 >/dev/null)"
rc=$?
[ "$rc" -eq 2 ] || exit 0

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
