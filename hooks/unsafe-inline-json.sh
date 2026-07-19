#!/usr/bin/env bash
# PreToolUse hook on Bash. Blocks brittle inline JSON parsing through
# node -e / python -c quoting, where fleet transcripts repeatedly show failures.
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

emit_deny() {
  # Deny the tool call and surface the reason, but never halt the session:
  # "continue": false here killed entire agent turns on every violation
  # (Tom, 2026-07-18). Deny alone lets the agent retry compliantly.
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null && exit 0
  printf '%s\n' "$reason" >&2
  exit 2
}

matches_node_json=0
matches_python_json=0
matches_python_fstring_index=0

if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])node[[:space:]]+(-[[:alnum:]]*[e][[:alnum:]]*|-e)[[:space:]]' \
  && printf '%s' "$cmd" | grep -q 'JSON\.parse'; then
  matches_node_json=1
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])python3?[[:space:]]+(-[[:alnum:]]*[c][[:alnum:]]*|-c)[[:space:]]' \
  && printf '%s' "$cmd" | grep -qE 'json\.loads?\('; then
  matches_python_json=1
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])python3?[[:space:]]+(-[[:alnum:]]*[c][[:alnum:]]*|-c)[[:space:]]' \
  && printf '%s' "$cmd" | grep -qE 'f["'\''][^"'\'']*\[\\?["'\''][^"'\'']+\\?["'\'']\]'; then
  matches_python_fstring_index=1
fi

if [ "$matches_node_json" -eq 0 ] && [ "$matches_python_json" -eq 0 ] && [ "$matches_python_fstring_index" -eq 0 ]; then
  exit 0
fi

emit_deny "BLOCKED: unsafe inline JSON parsing in Bash.

This command uses node -e / python -c with JSON.parse, json.load/json.loads, or a fragile f-string [\"...\"] index. That quoting pattern is a recurring fleet failure.

Hint: for socket/API JSON, pipe to last-stack-json-get .field after sourcing last-stack-shell-prelude. For richer parsing, use jq when available or write a small .py file in scratchpad and run the file. Avoid -c/-e JSON quoting."
