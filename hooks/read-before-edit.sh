#!/usr/bin/env bash
# PreToolUse hook for Edit/Write. Blocks edits to existing files that have not
# been read with the Read tool in this Claude session.
set -u

input="$(cat)" || exit 0

command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
case "$tool" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

emit_deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    continue: false,
    stopReason: $r,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null || printf '%s\n' "$reason" >&2
  exit 1
}

abspath() {
  local path="$1"
  local cwd="$2"
  local dir base

  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) path="${cwd:-$PWD}/$path" ;;
  esac

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd "$dir" 2>/dev/null && pwd -P)" "$base"
  else
    printf '%s\n' "$path"
  fi
}

is_scratchpad_path() {
  local path="$1"
  case "$path" in
    /tmp/*|/private/tmp/*|/var/tmp/*) return 0 ;;
  esac
  if [ -n "${TMPDIR:-}" ]; then
    case "$path" in "$TMPDIR"/*) return 0 ;; esac
  fi
  case "$path" in
    "$HOME/.claude/scratch"/*|"$HOME/.codex/scratch"/*|"$HOME/.scratch"/*|*/scratchpad/*)
      return 0
      ;;
  esac
  return 1
}

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || echo "")"
[ -n "$path" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
target="$(abspath "$path" "$cwd" 2>/dev/null || true)"
[ -n "$target" ] || exit 0

# New-file writes and scratchpad writes are intentionally allowed.
if [ "$tool" = "Write" ]; then
  [ ! -e "$target" ] && exit 0
  is_scratchpad_path "$target" && exit 0
fi

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"
[ -f "$transcript" ] || exit 0

read_paths="$(jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use" and .name == "Read")
  | .input.file_path // empty
' "$transcript" 2>/dev/null || true)"

while IFS= read -r read_path; do
  [ -n "$read_path" ] || continue
  read_abs="$(abspath "$read_path" "$cwd" 2>/dev/null || true)"
  [ "$read_abs" = "$target" ] && exit 0
done <<< "$read_paths"

emit_deny "BLOCKED: $tool on $target before Read.

Read the file first in this session, then retry the $tool. This prevents stale-context edits and the recurring \"File has not been read yet\" tool failure.

Hint: run the Read tool on:
  $target"
